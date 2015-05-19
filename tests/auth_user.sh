#!/bin/bash

if [[ $# -lt 1 ]]; then
	echo "User id are required"
	exit 1
fi

user_id=$1
if [[ $# -lt 2 ]]; then
	protocol="http"
else
	protocol=$2
fi

sed -e "s/<USER_ID>/$user_id/" auth_user_request.json.template > auth_user_request.json

curl -v -k -d@auth_user_request.json -H "Content-Type: application/json" ${protocol}://localhost:35357/v3/auth/tokens
