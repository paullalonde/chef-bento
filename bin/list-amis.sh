#!/bin/bash

set -euo pipefail

aws ec2 describe-images \
    --profile icible-dev-dev \
    --region ca-central-1 \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*" "Name=state,Values=available" \
    | jq '.Images|[.[]|select(.Architecture == "x86_64")|select(.ImageLocation|contains("-kernel-6.1-"))|.Name|gsub("^al2023-ami-(?<vers>[.0-9]+)-.+$"; "\(.vers)")]|sort|reverse'
