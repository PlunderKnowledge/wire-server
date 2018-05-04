#!/usr/bin/env sh

exec_until_ready() {
	until $1; do echo 'service not ready yet'; sleep 1; done
}

# Assumes this to be run in an environment with `aws` installed
echo 'Creating AWS resources'
aws configure set aws_access_key_id dummykey
aws configure set aws_secret_access_key dummysecret
aws configure set region eu-west-1

aws --endpoint-url=http://s3:9000 s3api create-bucket --bucket dummy-bucket

echo 'AWS resources created successfully!'
