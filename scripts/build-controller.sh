#!/usr/bin/env bash

# A script that builds a single ACK service controller for an AWS service API

set -eo pipefail

SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$SCRIPTS_DIR/.."
BIN_DIR="$ROOT_DIR/bin"

source "$SCRIPTS_DIR/lib/common.sh"

check_is_installed controller-gen "You can install controller-gen with the helper scripts/install-controller-gen.sh"

if ! k8s_controller_gen_version_equals "$CONTROLLER_TOOLS_VERSION"; then
    echo "FATAL: Existing version of controller-gen "`controller-gen --version`", required version is $CONTROLLER_TOOLS_VERSION."
    echo "FATAL: Please uninstall controller-gen and install the required version with scripts/install-controller-gen.sh."
    exit 1
fi

ACK_GENERATE_CACHE_DIR=${ACK_GENERATE_CACHE_DIR:-"$HOME/.cache/aws-controllers-k8s"}
# The ack-generate code generator is in a separate source code repository,
# typically at $GOPATH/src/github.com/aws-controllers-k8s/code-generator
DEFAULT_ACK_GENERATE_BIN_PATH="$ROOT_DIR/bin/ack-generate"
ACK_GENERATE_BIN_PATH=${ACK_GENERATE_BIN_PATH:-$DEFAULT_ACK_GENERATE_BIN_PATH}
ACK_GENERATE_API_VERSION=${ACK_GENERATE_API_VERSION:-"v1alpha1"}
ACK_GENERATE_CONFIG_PATH=${ACK_GENERATE_CONFIG_PATH:-""}
ACK_METADATA_CONFIG_PATH=${ACK_METADATA_CONFIG_PATH:-""}
ACK_GENERATE_SERVICE_ACCOUNT_NAME=${ACK_GENERATE_SERVICE_ACCOUNT_NAME:-"ack-$SERVICE-controller"}
AWS_SDK_GO_VERSION=${AWS_SDK_GO_VERSION:-""}
DEFAULT_RUNTIME_CRD_DIR="$ROOT_DIR/../../aws-controllers-k8s/runtime/config"
RUNTIME_CRD_DIR=${RUNTIME_CRD_DIR:-$DEFAULT_RUNTIME_CRD_DIR}
K8S_RBAC_ROLE_NAME=${K8S_RBAC_ROLE_NAME:-"ack-$SERVICE-controller"}

USAGE="
Usage:
  $(basename "$0") <service>

<service> should be an AWS service API aliases that you wish to build -- e.g.
's3' 'sns' or 'sqs'

Environment variables:
  ACK_GENERATE_CACHE_DIR:               Overrides the directory used for caching AWS API
                                        models used by the ack-generate tool.
                                        Default: $ACK_GENERATE_CACHE_DIR
  ACK_GENERATE_BIN_PATH:                Overrides the path to the the ack-generate binary.
                                        Default: $ACK_GENERATE_BIN_PATH
  ACK_GENERATE_API_VERSION:             Overrides the version of the Kubernetes API objects
                                        generated by the ack-generate apis command. If not
                                        specified, and the service controller has been
                                        previously generated, the latest generated API
                                        version is used. If the service controller has yet
                                        to be generated, 'v1alpha1' is used.
  ACK_GENERATE_CONFIG_PATH:             Specify a path to the generator config YAML file to
                                        instruct the code generator for the service.
                                        Default: generator.yaml
  ACK_METADATA_CONFIG_PATH:             Specify a path to the metadata config YAML file to
                                        instruct the code generator for the service.
                                        Default: metadata.yaml
  ACK_GENERATE_SERVICE_ACCOUNT_NAME:    Name of the Kubernetes Service Account and
                                        Cluster Role to use in Helm chart.
                                        Default: $ACK_GENERATE_SERVICE_ACCOUNT_NAME
  AWS_SDK_GO_VERSION:                   Overrides the version of github.com/aws/aws-sdk-go used
                                        by 'ack-generate' to fetch the service API Specifications.
                                        Default: Version of aws/aws-sdk-go in service go.mod
  TEMPLATES_DIR:                        Overrides the directory containg ack-generate templates
                                        Default: $TEMPLATES_DIR
  K8S_RBAC_ROLE_NAME:                   Name of the Kubernetes Role to use when generating
                                        the RBAC manifests for the custom resource
                                        definitions.
                                        Default: $K8S_RBAC_ROLE_NAME
"

if [ $# -ne 1 ]; then
    echo "ERROR: $(basename "$0") only accepts a single parameter" 1>&2
    echo "$USAGE"
    exit 1
fi

if [ ! -f $ACK_GENERATE_BIN_PATH ]; then
    if is_installed "ack-generate"; then
        ACK_GENERATE_BIN_PATH=$(which "ack-generate")
    else
        echo "ERROR: Unable to find an ack-generate binary.
Either set the ACK_GENERATE_BIN_PATH to a valid location or
run:
 
   make build-ack-generate
 
from the root directory or install ack-generate using:

   go get -u -tags codegen github.com/aws-controllers-k8s/code-generator/cmd/ack-generate" 1>&2
        exit 1;
    fi
fi
SERVICE=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# Source code for the controller will be in a separate repo, typically in
# $GOPATH/src/github.com/aws-controllers-k8s/$AWS_SERVICE-controller/
DEFAULT_SERVICE_CONTROLLER_SOURCE_PATH="$ROOT_DIR/../$SERVICE-controller"
SERVICE_CONTROLLER_SOURCE_PATH=${SERVICE_CONTROLLER_SOURCE_PATH:-$DEFAULT_SERVICE_CONTROLLER_SOURCE_PATH}

if [[ ! -d $SERVICE_CONTROLLER_SOURCE_PATH ]]; then
    echo "Error evaluating SERVICE_CONTROLLER_SOURCE_PATH environment variable:" 1>&2
    echo "$SERVICE_CONTROLLER_SOURCE_PATH is not a directory." 1>&2
    echo "${USAGE}"
    exit 1
fi

BOILERPLATE_TXT_PATH="$ROOT_DIR/templates/boilerplate.txt"
DEFAULT_TEMPLATE_DIRS="$ROOT_DIR/templates"
# If the service controller source repository has a templates/ directory, add
# that as a template base directory to search for templates in.
# Note that ack-generate accepts multiple template paths for its
# `--template-dirs` CLI flag. The order of these template directories is
# important, as it indicates the order in which the code generator will search
# for template files to use. Developers of a service controller can essentially
# "override" the default template used for various things by adding a
# same-named template file into a templates/ directory in their service
# controller.
if [[ -d "$SERVICE_CONTROLLER_SOURCE_PATH/templates" ]]; then
    DEFAULT_TEMPLATE_DIRS="$SERVICE_CONTROLLER_SOURCE_PATH/templates,$DEFAULT_TEMPLATE_DIRS"
    if [[ -f "$SERVICE_CONTROLLER_SOURCE_PATH/templates/boilerplate.txt" ]]; then
        BOILERPLATE_TXT_PATH="$SERVICE_CONTROLLER_SOURCE_PATH/templates/boilerplate.txt"
    fi
fi

TEMPLATE_DIRS=${TEMPLATE_DIRS:-$DEFAULT_TEMPLATE_DIRS}

config_output_dir="$SERVICE_CONTROLLER_SOURCE_PATH/config/"

echo "Copying common custom resource definitions into $SERVICE"
mkdir -p $config_output_dir/crd/common
cp -r $RUNTIME_CRD_DIR/crd/* $config_output_dir/crd/common/

if [ -z "$AWS_SDK_GO_VERSION" ]; then
    AWS_SDK_GO_VERSION=$(go list -m -f '{{ .Version }}' -modfile $SERVICE_CONTROLLER_SOURCE_PATH/go.mod github.com/aws/aws-sdk-go)
fi

# If there's a generator.yaml in the service's directory and the caller hasn't
# specified an override, use that.
if [ -z "$ACK_GENERATE_CONFIG_PATH" ]; then
    if [ -f "$SERVICE_CONTROLLER_SOURCE_PATH/generator.yaml" ]; then
        ACK_GENERATE_CONFIG_PATH="$SERVICE_CONTROLLER_SOURCE_PATH/generator.yaml"
    fi
fi

# If there's a metadata.yaml in the service's directory and the caller hasn't
# specified an override, use that.
if [ -z "$ACK_METADATA_CONFIG_PATH" ]; then
    if [ -f "$SERVICE_CONTROLLER_SOURCE_PATH/metadata.yaml" ]; then
        ACK_METADATA_CONFIG_PATH="$SERVICE_CONTROLLER_SOURCE_PATH/metadata.yaml"
    fi
fi

ag_args="$SERVICE -o $SERVICE_CONTROLLER_SOURCE_PATH --template-dirs $TEMPLATE_DIRS"
if [ -n "$ACK_GENERATE_CACHE_DIR" ]; then
    ag_args="$ag_args --cache-dir $ACK_GENERATE_CACHE_DIR"
fi

apis_args="apis $ag_args"
if [ -n "$ACK_GENERATE_API_VERSION" ]; then
    apis_args="$apis_args --version $ACK_GENERATE_API_VERSION"
fi

if [ -n "$ACK_GENERATE_CONFIG_PATH" ]; then
    ag_args="$ag_args --generator-config-path $ACK_GENERATE_CONFIG_PATH"
    apis_args="$apis_args --generator-config-path $ACK_GENERATE_CONFIG_PATH"
fi

if [ -n "$ACK_METADATA_CONFIG_PATH" ]; then
    ag_args="$ag_args --metadata-config-path $ACK_METADATA_CONFIG_PATH"
    apis_args="$apis_args --metadata-config-path $ACK_METADATA_CONFIG_PATH"
fi

if [ -n "$AWS_SDK_GO_VERSION" ]; then
    ag_args="$ag_args --aws-sdk-go-version $AWS_SDK_GO_VERSION"
    apis_args="$apis_args --aws-sdk-go-version $AWS_SDK_GO_VERSION"
fi

if [ -n "$ACK_GENERATE_SERVICE_ACCOUNT_NAME" ]; then
    ag_args="$ag_args --service-account-name $ACK_GENERATE_SERVICE_ACCOUNT_NAME"
fi

echo "Building Kubernetes API objects for $SERVICE"
$ACK_GENERATE_BIN_PATH $apis_args
if [ $? -ne 0 ]; then
    exit 2
fi

pushd $SERVICE_CONTROLLER_SOURCE_PATH/apis/$ACK_GENERATE_API_VERSION 1>/dev/null

echo "Generating deepcopy code for $SERVICE"
controller-gen object:headerFile=$BOILERPLATE_TXT_PATH paths=./...

echo "Generating custom resource definitions for $SERVICE"
# Latest version of controller-gen (master) is required for following two reasons
# a) support for pointer values in map https://github.com/kubernetes-sigs/controller-tools/pull/317
# b) support for float type (allowDangerousTypes) https://github.com/kubernetes-sigs/controller-tools/pull/449
controller-gen crd:allowDangerousTypes=true paths=./... output:crd:artifacts:config=$config_output_dir/crd/bases

popd 1>/dev/null

echo "Building service controller for $SERVICE"
controller_args="controller $ag_args"
$ACK_GENERATE_BIN_PATH $controller_args
if [ $? -ne 0 ]; then
    exit 2
fi

pushd $SERVICE_CONTROLLER_SOURCE_PATH/pkg/resource 1>/dev/null

echo "Generating RBAC manifests for $SERVICE"
controller-gen rbac:roleName=$K8S_RBAC_ROLE_NAME paths=./... output:rbac:artifacts:config=$config_output_dir/rbac
# controller-gen rbac outputs a ClusterRole definition in a
# $config_output_dir/rbac/role.yaml file. We have some other standard Role
# files for a reader and writer role, so here we rename the `role.yaml` file to
# `cluster-role-controller.yaml` to better reflect what is in that file.
mv $config_output_dir/rbac/role.yaml $config_output_dir/rbac/cluster-role-controller.yaml
# Copy definitions for json patches which allow the user to patch the controller
# with Role/Rolebinding and be purely namespaced scoped instead of using Cluster/ClusterRoleBinding
# using kustomize
mkdir -p $config_output_dir/overlays/namespaced
cp -r $ROOT_DIR/templates/config/overlays/namespaced/*.json $config_output_dir/overlays/namespaced

popd 1>/dev/null

echo "Running gofmt against generated code for $SERVICE"
gofmt -w "$SERVICE_CONTROLLER_SOURCE_PATH"

echo "Updating additional GitHub repository maintenance files"
cp "$ROOT_DIR"/CODE_OF_CONDUCT.md "$SERVICE_CONTROLLER_SOURCE_PATH"/CODE_OF_CONDUCT.md
cp "$ROOT_DIR"/CONTRIBUTING.md "$SERVICE_CONTROLLER_SOURCE_PATH"/CONTRIBUTING.md
cp "$ROOT_DIR"/GOVERNANCE.md "$SERVICE_CONTROLLER_SOURCE_PATH"/GOVERNANCE.md
cp "$ROOT_DIR"/LICENSE "$SERVICE_CONTROLLER_SOURCE_PATH"/LICENSE
cp "$ROOT_DIR"/NOTICE "$SERVICE_CONTROLLER_SOURCE_PATH"/NOTICE
