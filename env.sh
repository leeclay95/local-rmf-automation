# Point this shell at the local Floci emulator — and ONLY at it.
#
#   source ./env.sh      (from the repo root; works from any clone location)
#
# This deliberately redirects AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE at
# lab-local files, so nothing in this lab can read ~/.aws/credentials. Every
# credential used here is minted by Floci's own IAM emulator and exists only
# inside ./data. No request ever leaves this machine.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Compose project name, and the Docker network Floci puts its real containers on.
# This is pinned rather than derived from the directory name: Compose defaults the
# project to the folder it finds the file in, so a clone into any other directory
# would silently rename the network and break Floci's FLOCI_SERVICES_DOCKER_NETWORK,
# the ALB target lookups and the teardown script. docker-compose.yml sets the same
# value in its top-level `name:`. Override both together, or neither.
export LAB_PROJECT="${LAB_PROJECT:-stig-cloud-lab}"
export LAB_NETWORK="${LAB_NETWORK:-${LAB_PROJECT}_default}"

export AWS_CONFIG_FILE="$LAB_DIR/aws/config"
export AWS_SHARED_CREDENTIALS_FILE="$LAB_DIR/aws/credentials"
export AWS_PROFILE="floci-lab"

export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_DEFAULT_REGION="us-east-2"
export AWS_REGION="us-east-2"

# Never let a real instance/container credential source answer.
export AWS_EC2_METADATA_DISABLED="true"
unset AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# Lab-local kubeconfig, so ~/.kube/config stays untouched.
export KUBECONFIG="$LAB_DIR/kubeconfig"

echo "AWS -> Floci   endpoint=$AWS_ENDPOINT_URL region=$AWS_REGION profile=$AWS_PROFILE"
echo "creds file     $AWS_SHARED_CREDENTIALS_FILE  (emulated only)"
echo "kubeconfig     $KUBECONFIG"
