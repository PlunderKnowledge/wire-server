{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module API.User.Util where

import Bilge hiding (accept, timeout)
import Bilge.Assert
import Brig.Types
import Brig.Types.Intra
import Brig.Types.User.Auth hiding (user)
import Brig.Data.PasswordReset
import Control.Lens ((^?), preview)
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson
import Data.Aeson.Lens
import Data.ByteString (ByteString)
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Char8 (pack)
import Data.ByteString.Conversion
import Data.Id hiding (client)
import Data.Int (Int64)
import Data.List (sort)
import Data.Maybe
import Data.Misc (PlainTextPassword(..))
import Data.Range (unsafeRange)
import Data.Text (Text)
import OpenSSL.EVP.Digest (getDigestByName, digestBS)
import Test.Tasty.HUnit
import Util

import qualified CargoHold.Types.V3          as CHV3
import qualified Codec.MIME.Type             as MIME
import qualified Data.ByteString.Lazy        as LB
import qualified Data.Set                    as Set
import qualified Data.Text.Ascii             as Ascii
import qualified Data.Text.Encoding          as T
import qualified Data.Vector                 as Vec

newtype ConnectionLimit = ConnectionLimit Int64

checkHandles :: Brig -> UserId -> [Text] -> Word -> Http ResponseLBS
checkHandles brig uid hs num =
    let hs'  = unsafeRange hs
        num' = unsafeRange num
        js   = RequestBodyLBS $ encode $ CheckHandles hs' num'
    in post (brig . path "/users/handles" . contentJson . zUser uid . body js)

-- Note: This actually _will_ send out an email so make sure we don't use any
--       inexistent email addresses or ones that bounce! Perhaps we should
--       ensure that the email used here has a domain 'simulator.amazonses.com'
-- TODO: register
registerUser :: Text -> Text -> Brig -> Http ResponseLBS
registerUser name email brig = do
    e <- mkEmail email
    let p = RequestBodyLBS . encode $ object
            [ "name"     .= name
            , "email"    .= fromEmail e
            , "password" .= defPassword
            ]
    post (brig . path "/register" . contentJson . body p)

createRandomPhoneUser :: Brig -> Http (UserId, Phone)
createRandomPhoneUser brig = do
    usr <- randomUser brig
    let uid = userId usr
    phn <- liftIO randomPhone
    -- update phone
    let phoneUpdate = RequestBodyLBS . encode $ PhoneUpdate phn
    put (brig . path "/self/phone" . contentJson . zUser uid . zConn "c" . body phoneUpdate) !!!
        (const 202 === statusCode)
    -- activate
    act <- getActivationCode brig (Right phn)
    case act of
        Nothing -> liftIO $ assertFailure "missing activation key/code"
        Just kc -> activate brig kc !!! const 200 === statusCode
    -- check new phone
    get (brig . path "/self" . zUser uid) !!! do
        const 200 === statusCode
        const (Just phn) === (userPhone <=< decodeBody)

    return (uid, phn)

initiatePasswordReset :: Brig -> Email -> Http ResponseLBS
initiatePasswordReset brig email =
    post ( brig
         . path "/password-reset"
         . contentJson
         . body (RequestBodyLBS . encode $ NewPasswordReset (Left email))
         )

activateEmail :: Brig -> Email -> HttpT IO ()
activateEmail brig email = do
    act <- getActivationCode brig (Left email)
    case act of
        Nothing -> liftIO $ assertFailure "missing activation key/code"
        Just kc -> activate brig kc !!! do
            const 200 === statusCode
            const(Just False) === fmap activatedFirst . decodeBody

checkEmail :: Brig -> UserId -> Email -> HttpT IO ()
checkEmail brig uid expectedEmail =
    get (brig . path "/self" . zUser uid) !!! do
        const 200 === statusCode
        const (Just expectedEmail) === (userEmail <=< decodeBody)

initiateEmailUpdate :: Brig -> Email -> UserId -> Http ResponseLBS
initiateEmailUpdate brig email uid =
    let emailUpdate = RequestBodyLBS . encode $ EmailUpdate email in
    put (brig . path "/self/email" . contentJson . zUser uid . zConn "c" . body emailUpdate)

preparePasswordReset :: Brig -> Email -> UserId -> PlainTextPassword -> Http CompletePasswordReset
preparePasswordReset brig email uid newpw = do
    let qry = queryItem "email" (toByteString' email)
    r <- get $ brig . path "/i/users/password-reset-code" . qry
    let lbs = fromMaybe "" $ responseBody r
    let Just pwcode = PasswordResetCode . Ascii.unsafeFromText <$> (lbs ^? key "code" . _String)
    ident <- PasswordResetIdentityKey <$> mkPasswordResetKey uid
    let complete = CompletePasswordReset ident pwcode newpw
    return complete

completePasswordReset :: Brig -> CompletePasswordReset -> Http ResponseLBS
completePasswordReset brig passwordResetData =
    post ( brig
         . path "/password-reset/complete"
         . contentJson
         . body (RequestBodyLBS $ encode passwordResetData)
         )

removeBlacklist :: Brig -> Email -> Http ()
removeBlacklist brig email =
    void $ delete (brig . path "/i/users/blacklist" . queryItem "email" (toByteString' email))

getInvitationCode :: Brig -> UserId -> InvitationId -> Http (Maybe InvitationCode)
getInvitationCode brig u ref = do
    r <- get ( brig
             . path "/i/users/invitation-code"
             . queryItem "inviter" (toByteString' u)
             . queryItem "invitation_id" (toByteString' ref)
             )
    let lbs   = fromMaybe "" $ responseBody r
    return $ fromByteString . fromMaybe (error "No code?") $ T.encodeUtf8 <$> (lbs ^? key "code"  . _String)

getInvitation :: Brig -> InvitationCode -> Http (Maybe Invitation)
getInvitation brig c = do
    r <- get $ brig
             . path "/invitations/info"
             . queryItem "code" (toByteString' c)
    return . decode . fromMaybe "" $ responseBody r

getClient :: Brig -> UserId -> ClientId -> Http ResponseLBS
getClient brig u c = get $ brig
    . paths ["clients", toByteString' c]
    . zUser u

deleteClient :: Brig -> UserId -> ClientId -> Maybe PlainTextPassword -> Http ResponseLBS
deleteClient brig u c pw = delete $ brig
    . paths ["clients", toByteString' c]
    . zUser u
    . zConn "conn"
    . contentJson
    . body payload
  where
    payload = RequestBodyLBS . encode $ object
        [ "password" .= pw
        ]

listConnections :: Brig -> UserId -> Http ResponseLBS
listConnections brig u = get $ brig
    . path "connections"
    . zUser u

postInvitation :: Brig -> UserId -> InvitationRequest -> Http ResponseLBS
postInvitation brig u i = post $ brig
    . path "invitations"
    . contentJson
    . body (RequestBodyLBS $ encode i)
    . zUser u
    . zConn "conn"

postAutoConnection :: Brig -> UserId -> [UserId] -> Http ResponseLBS
postAutoConnection brig from to = post $ brig
    . paths ["/i/users", toByteString' from, "auto-connect"]
    . contentJson
    . body payload
    . zConn "conn"
  where
    payload = RequestBodyLBS . encode $ UserSet (Set.fromList to)

setProperty :: Brig -> UserId -> ByteString -> Value -> Http ResponseLBS
setProperty brig u k v = put $ brig
    . paths ["/properties", k]
    . zUser u
    . zConn "conn"
    . contentJson
    . body (RequestBodyLBS $ encode v)

getProperty :: Brig -> UserId -> ByteString -> Http ResponseLBS
getProperty brig u k = get $ brig
    . paths ["/properties", k]
    . zUser u

deleteProperty :: Brig -> UserId -> ByteString -> Http ResponseLBS
deleteProperty brig u k = delete $ brig
    . paths ["/properties", k]
    . zConn "conn"
    . zUser u

countCookies :: Brig -> UserId -> CookieLabel -> Http (Maybe Int)
countCookies brig u label = do
    r <- get ( brig
             . path "/cookies"
             . queryItem "labels" (toByteString' label)
             . header "Z-User" (toByteString' u)
             ) <!! const 200 === statusCode
    return $ Vec.length <$> (preview (key "cookies" . _Array) =<< asValue r)

assertConnections :: Brig -> UserId -> [ConnectionStatus] -> Http ()
assertConnections brig u cs = listConnections brig u !!! do
    const 200 === statusCode
    const (Just True) === fmap (check . map status . clConnections) . decodeBody
  where
    check xs = all (`elem` xs) cs
    status c = ConnectionStatus (ucFrom c) (ucTo c) (ucStatus c)

assertEmailVisibility :: Brig -> User -> User -> Bool -> Http ()
assertEmailVisibility brig a b visible =
    get (brig . paths ["users", pack . show $ userId b] . zUser (userId a)) !!! do
        const 200 === statusCode
        if visible
            then const (Just (userEmail b)) === fmap userEmail . decodeBody
            else const Nothing === (userEmail <=< decodeBody)

uploadAsset :: CargoHold -> UserId -> ByteString -> Http CHV3.Asset
uploadAsset c usr dat = do
    let sts = CHV3.defAssetSettings
        ct  = MIME.Type (MIME.Application "text") []
        mpb = CHV3.buildMultipartBody sts ct (LB.fromStrict dat)
    rsp <- post ( c
                . path "/assets/v3"
                . zUser usr
                . zConn "conn"
                . content "multipart/mixed"
                . lbytes (toLazyByteString mpb)
                ) <!! const 201 === statusCode
    return $ fromMaybe (error "Failed to decode asset body") (decodeBody rsp)

downloadAsset :: CargoHold -> UserId -> ByteString -> Http (Response (Maybe LB.ByteString))
downloadAsset c usr ast =
    get ( c
        . paths ["/assets/v3", ast]
        . zUser usr
        . zConn "conn"
        )

uploadAddressBook :: Brig -> UserId -> AddressBook -> MatchingResult -> Http ()
uploadAddressBook b u a m =
    post ( b
         . path "/onboarding/v3"
         . contentJson
         . zUser u
         . body (RequestBodyLBS $ encode a)
         ) !!! do
            const 200 === statusCode
            const (Just (f m)) === (fmap f . decodeBody)
  where
    f :: MatchingResult -> MatchingResult
    f (MatchingResult x y) = MatchingResult (sort x) (sort y)

-- Builds expectations on the matched users/cards
toMatchingResult :: [(UserId, Text)] -> MatchingResult
toMatchingResult xs = MatchingResult
                      (map (\(u, c) -> Match u (Just (CardId c)) [CardId c]) xs)
                      (Set.toList $ Set.fromList (map fst xs))

-- Hashes each entry and builds an appropriate address book
toAddressBook :: [(Text, [Text])] -> IO AddressBook
toAddressBook xs = do
    Just sha <- liftIO $ getDigestByName "SHA256"
    return . AddressBook $ fmap (toCard sha) xs
  where
    toCard sha (cardId, entries) = Card (Just $ CardId cardId)
                                        (map (Entry . digestBS sha . T.encodeUtf8) entries)
