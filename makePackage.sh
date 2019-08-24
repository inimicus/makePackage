#!/usr/bin/env bash
# =============================================================================
# makePackage.sh
# Author:  g4rr3t
# Updated: 2019-08-12
#
# Create a fancy zip package of an addon and maybe do other things too.
# =============================================================================

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

PROGRAM_NAME="$(basename -- "$0")"
PROGRAM_VERSION="1.0.0"

VERSION_PATTERN="^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(\\.| r)(0|[1-9][0-9]*)$"

DEFAULT_RELEASE_DIR="release"
DEFAULT_COMMIT="Added packaged version %s"
DEFAULT_COMMIT_BUMP="Bumped to version %s"
DEFAULT_COMMIT_BUMP_API="Bumped API to %s"
DEFAULT_COMMIT_BODY="Automatically committed via ${PROGRAM_NAME} v${PROGRAM_VERSION}"

PROGRAM_USAGE_SHORT="\
Usage:

  $PROGRAM_NAME [options]
  $PROGRAM_NAME bump [(--to | -t) <version>] [--major | --minor | --patch] [options]
  $PROGRAM_NAME bump-api [(--to | -t) <version>] [--squash | -s] [options]
  $PROGRAM_NAME (--help | -h)
  $PROGRAM_NAME (--version | -v)"

PROGRAM_USAGE_FULL="\
$PROGRAM_NAME version $PROGRAM_VERSION

$PROGRAM_USAGE_SHORT

Take the contents of an entire addon directory and output a packaged zip file
that is clean of development, debug, and OS-specific artifacts that is ready
to be distributed or uploaded to ESOUI.

Reads the directory name and package manifest file for information about the addon,
including any options to ignore addon-specific files and folders, where to place
the output package, and more.

For more configuration information, issues, or feature requests, visit:

    https://github.com/inimicus/makePackage/

Options:

  --dry-run             Print out commands to execute without executing them.
                        Short: -d

  --no-commit           Disables automatic commit.
                        Short: -n

  --message <message>   Specify a message for the commit.
                        When a message is not specified, the default
                        message will be used.
                        Short: -m

Commands:
  bump        Bump the addon version by one patch and commit the change.

              Options:

              --major             Bumps the major version.

              --minor             Bumps the minor version.

              --patch             Bumps the patch version (default).

              --to <version>      Explicitly set the addon version to bump to.
                                  When set, options passed to bump the major,
                                  minor, or patch number are ignored.
                                  Short: -t

  bump-api    Bump the API version by one. If multiple API versions are
              found in the manifest file, each will be incremented by one.

              Options:

              --squash            If multiple API versions are encountered, bump
                                  the most recent version and remove the rest.
                                  Short: -s

              --to <version>      Explicitly set the API version to bump to.
                                  Short: -t

Examples:
  $PROGRAM_NAME
    Create a package and commit with the default message.

  $PROGRAM_NAME --no-commit
    Create a package, skip auto commit.

  $PROGRAM_NAME -m \"Add my sweet packaged addon that isn't broken at all.\"
    Create a package and commit with a specific message.

  $PROGRAM_NAME bump
    Bump addon to the next patch version and commit with the default message.

  $PROGRAM_NAME bump --minor
    Bump addon to the next minor version and commit with the default message.

  $PROGRAM_NAME bump -t \"2.3.4\" -m \"Let's hope this version is less broken.\"
    Bump addon version to 2.3.4 and commit with a specific message.

  $PROGRAM_NAME bump-api -s
    Bump the API version and remove any previous API versions.

  $PROGRAM_NAME bump-api --to \"100123 100234\"
    Explicitly set the API version and commit with the default message."


# Utility Functions -----------------------------------------------------------

function error() {
    echo -e "$1" >&2
    exit 1
}

function error_usage() {
    echo -e "$1\n\nUse '${PROGRAM_NAME} --help' for more information." 1>&2
    exit 2
}

function usage() {
    echo -e "$PROGRAM_USAGE_FULL"
}

function get_addon_path() {
    local working manifest
    working="${PWD}"

    # Check the working directory exists
    if [[ -d "${working}" ]]; then
        # Check existence of manifest file
        manifest=$(get_manifest_file) || exit 1
        echo "${working}"
    else
        error "Invalid directory path!"
    fi
}

function get_manifest_addon_version() {
    get_manifest_variable "AddOnVersion"
}

function get_manifest_version() {
    get_manifest_variable "Version"
}

function get_manifest_excludes() {
    get_manifest_option "PackageExcludes"
}

function get_manifest_release_dir() {
    get_manifest_option "PackageReleaseDir"
}

function get_manifest_bump_files() {
    get_manifest_option "PackageBumpFiles"
}

function generate_next_version() {
    local addonVersion major minor type patch nextVersion

    addonVersion="$1"

    # Use explicit next version if it has been passed
    # Otherwise generate the next version based on the current version
    if [ -z ${ADDON_NEXT_VERSION+x} ]; then

        if [[ "$addonVersion" =~ $VERSION_PATTERN ]]; then
            major=${BASH_REMATCH[1]}
            minor=${BASH_REMATCH[2]}
            type=${BASH_REMATCH[3]}
            patch=${BASH_REMATCH[4]}

            case "${BUMP_TYPE:-patch}" in
                major)
                    major="$((major + 1))"
                    minor=0
                    patch=0
                    ;;
                minor)
                    minor="$((minor + 1))"
                    patch=0
                    ;;
                patch)
                    patch="$((patch + 1))"
                    ;;
                *)
                    error_usage "Invalid bump option: ${BUMP_TYPE}"
                    ;;
            esac

            if [[ $type = "." ]]; then
                nextVersion="${major}.${minor}.${patch}"
            else
                if [[ $patch = "0" ]]; then
                    patch=1
                fi
                nextVersion="${major}.${minor} r${patch}"
            fi

        else
            error "Current version $addonVersion is not a compatible version format (X.Y.Z or X.Y rZ)"
        fi
    else
        nextVersion="${ADDON_NEXT_VERSION}"
    fi

    # Confirm passed or generated next version is valid
    if [[ "$nextVersion" =~ $VERSION_PATTERN ]]; then
        echo "$nextVersion"
    else
        error "Next version $nextVersion is not a compatible version format (X.Y.Z or X.Y rZ)"
    fi
}

function generate_next_add_on_version() {
    local version major minor type patch nextVersion

    version="$1"

    if [[ $version =~ $VERSION_PATTERN ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        type=${BASH_REMATCH[3]}
        patch=${BASH_REMATCH[4]}

        # Do not process large version parts
        if [[ $major -gt 99 ]] || [[ $minor -gt 99  ]] || [[ $patch -gt 99  ]]; then
            error "Version major, minor, or patch values greater than 99 are not supported."
        fi

        if [[ $type = "." ]]; then
            nextVersion=$(printf "%d%02d%02d" "${major}" "${minor}" "${patch}")
        else
            nextVersion="${patch}"
        fi

        echo "$nextVersion"

    else
        error "Version reference to generate AddOnVersion $version is not a compatible version format (X.Y.Z or X.Y rZ)"
    fi
}

function get_addon_name() {
    # Directory name, strip spaces
    echo "${PWD##*/}"
}

function get_manifest_file() {
    local manifest
    manifest="${PWD}/$(get_addon_name).txt"

    if [[ -f "${manifest}" ]]; then
        echo "${manifest}"
    else
        error "Could not locate manifest file!\n${manifest} does not exist."
    fi
}

function get_manifest_option() {
    get_manifest_value "; $1" || exit 1
}

function get_manifest_variable() {
    get_manifest_value "## $1" || exit 1
}

function get_manifest_value() {
    local config manifest

    manifest=$(validate_manifest_file) || exit 1

    config=$(grep "${1}" "${manifest}" | sed 's/.*: //')
    echo "${config}"
}

function validate_manifest_file() {
    local manifest hasCRLF
    manifest=$(get_manifest_file) || exit 1

    # Detect CRLF
    hasCRLF=$(grep -Ul "" "${manifest}")

    if [[ -n "$hasCRLF" ]]; then
        error "Bad line ending detected! Check the manifest file and try again."
    fi

    # Detect starting with colon (:)
    hasColon=$(grep -Ul -E "^:" "$manifest")

    if [[ -n "$hasColon" ]]; then
        error "Colon at start of line detected! Check the manifest file and try again."
    fi

    echo "$manifest"
}

function validate_addon_name() {
    local addonDir addonTitle
    addonDir=$(get_addon_name) || exit 1
    addonTitle=$(get_manifest_variable "Title") || exit 1

    if [[ $addonDir != "$addonTitle" ]]; then
        error "Directory name does not match addon manifest Title value."
    else
        echo "$addonTitle"
    fi
}

# Action Functions ------------------------------------------------------------

function package_execute() {
    local addonName addonVersion releaseDir packageName addonDir\
        excludeFiles systemExclude addonExclude exclude

    # Get variables we need
    addonPath=$(get_addon_path) || exit 1
    addonDir=$(basename "${addonPath}")
    addonName=$(validate_addon_name)
    addonVersion=$(get_manifest_version) || exit 1
    excludeFiles=$(get_manifest_excludes) || exit 1
    releaseDir=$(get_manifest_release_dir) || exit 1

    # Use the default if no release directory in manifest
    releaseDir=${releaseDir:-$DEFAULT_RELEASE_DIR}

    # Make sure release directory exists
    if [[ ! -d "${releaseDir}" ]]; then
        error "Could not make package: Release directory $releaseDir does not exist!"
    fi

    # Convert spaces to underscores in package name
    packageName="${addonName}-${addonVersion/ /_}.zip"
    packageOutput="${addonDir}/${releaseDir}/${packageName}"

    # Files to exclude
    excludeAll=""

    declare -a systemExclude=(
        "*.git*"
        "*.DS_Store"
        "Thumbs.db"
    )

    declare -a addonExclude=(
        "README.md"
        "${PROGRAM_NAME}"
        "${releaseDir}/*"
        "${releaseDir}/**/*"
    )

    read -r -a exclude <<< "$excludeFiles"

    # Prepend excludes with full directory path
    for item in "${systemExclude[@]}" "${addonExclude[@]}" "${exclude[@]}"
    do
        excludeAll="${excludeAll} ${addonDir}/${item}"
    done

    # Create package command
    packageCmd="zip -DqrX ${packageOutput} ${addonDir} -x ${excludeAll}"

    # Execute or print command when performing a dry run
    if [[ ${DO_DRY_RUN:-false} == true ]]; then
        echo "Dry Run Creating: ${packageName}"
        echo "$packageCmd"
        # TODO: Dry run commit command
    else
        echo -n "Creating: ${packageName}..."
        cd ..
        package="$(eval "${packageCmd}")"
        if [[ $package -eq 0 ]]; then
            echo "Done!"
            cd "$addonPath"
            # TODO: Commit package
        else
            error "Error!\nError occurred while creating the package."
        fi
    fi

}

function bump_execute() {
    local currentVersion nextVersion currentAddOnVersion nextAddOnVersion tempDir\
        tempManifest

    currentVersion="$(get_manifest_version)" || exit 1
    nextVersion="$(generate_next_version "${currentVersion}")" || exit 1
    currentAddOnVersion="$(get_manifest_addon_version)" || exit 1
    nextAddOnVersion="$(generate_next_add_on_version "${nextVersion}")" || exit 1

    tempDir="${TMPDIR-/tmp/}"
    manifestPath="$(get_manifest_file)" || exit 1
    manifestName="$(basename -- "${manifestPath}")"

    if [[ -d $tempDir ]]; then

        tempManifest="${tempDir}${manifestName}"
        man_copyCmd="cp ${manifestPath} ${tempManifest}"
        # TODO: Ensure portability of sed (-i '' is a macOS sed convention)
        man_replaceVersionCmd="sed -i '' -e 's/${currentVersion}/${nextVersion}/g' ${tempManifest}"
        man_replaceAddOnVersionCmd="sed -i '' -e 's/${currentAddOnVersion}/${nextAddOnVersion}/g' ${tempManifest}"
        man_moveCmd="mv ${tempManifest} ${manifestPath}"

        if [[ ${DO_DRY_RUN:-false} == true ]]; then
            echo "${man_copyCmd}"
            echo "${man_replaceVersionCmd}"
            echo "${man_replaceAddOnVersionCmd}"
            echo "${man_moveCmd}"
        else
            echo -n "Copying manifest to temp file... "
            man_copy="$(eval "${man_copyCmd}")"

            # Update Manifest
            if [[ $man_copy -eq 0 ]]; then
                if [[ -w $tempManifest ]]; then
                    echo "Done!"

                    # Replace Version
                    echo -n "Bumping manifest Version $currentVersion => $nextVersion... "
                    man_replaceVersion="$(eval "${man_replaceVersionCmd}")"
                    if [[ $man_replaceVersion -eq 0 ]]; then
                        echo "Done!"
                    else
                        error "Error!\nError occurred while updating the manifest Version."
                    fi

                    # Replace AddOnVersion
                    echo -n "Bumping manifest AddOnVersion $currentAddOnVersion => $nextAddOnVersion... "
                    man_replaceAddOnVersion="$(eval "${man_replaceAddOnVersionCmd}")"
                    if [[ $man_replaceAddOnVersion -eq 0 ]]; then
                        echo "Done!"
                    else
                        error "Error!\nError occurred while updating the manifest AddOnVersion."
                    fi

                    # Move updated manifest back
                    echo -n "Moving temporary manifest into place... "
                    man_move="$(eval "${man_moveCmd}")"
                    if [[ $man_move -eq 0 ]]; then
                        echo "Done!"
                    else
                        error "Error!\nError occurred while moving the updated manifest file."
                    fi
                else
                    error "Error!\nTemporary manifest file is not writable: ${tempManifest}"
                fi
            else
                error "Error!\nFailed copying manifest file."
            fi

            # Update Source Files
            # TODO: Update them
        fi

    else
        error "Temporary directory does not exist: ${tempDir}"
    fi
}

function bump_api_execute() {
    echo "Bumping API Version"
}

# Options ---------------------------------------------------------------------

function get_package_options() {
    local OPTIND o command

    command="package"

    # Set command mode
    if [[ $1 == "bump" ]] || [[ $1 == "bump-api" ]]; then
        command="${1}"
        shift $((OPTIND + 1))
    fi

    # Get options
    while getopts ":dm:nst:-:" o; do
        case "${o}" in
            -)
                case "${OPTARG}" in
                    dry-run)
                        DO_DRY_RUN=true
                        ;;
                    major|minor|patch)
                        if [[ ! $command == "bump" ]]; then
                            error_usage "The options for --major, --minor, and --patch have no effect in this command mode."
                        fi

                        BUMP_TYPE="${OPTARG}"
                        ;;
                    message)
                        if [[ -n ${!OPTIND+x} ]] && [[ ! ${!OPTIND:0:1} == "-" ]]; then
                            COMMIT_MESSAGE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
                        else
                            error_usage "Option --message requires a commit message."
                        fi
                        ;;
                    no-commit)
                        DO_COMMIT=false
                        ;;
                    squash)
                        if [[ ! $command == "bump-api" ]]; then
                            error_usage "The option for squashing API version have no effect in this command mode."
                        fi

                        DO_SQUASH=true
                        ;;
                    to)
                        if [[ $command == "package" ]]; then
                            error_usage "The option to set a version to bump to has no effect in this command mode."
                        fi

                        if [[ -n ${!OPTIND+x} ]] && [[ ! ${!OPTIND:0:1} == "-" ]]; then
                            ADDON_NEXT_VERSION="${!OPTIND}"; OPTIND=$((OPTIND + 1))
                        else
                            error_usage "Option --to requires a version."
                        fi
                        ;;
                    *)
                        error_usage "Unrecognized option provided: --${OPTARG}"
                        ;;
                esac;;
            d)
                DO_DRY_RUN=true
                ;;
            m)
                if [[ ! ${OPTARG:0:1} == "-" ]]; then
                    COMMIT_MESSAGE="${OPTARG}";
                else
                    error_usage "Option -m requires a valid commit message."
                fi
                ;;
            n)
                DO_COMMIT=false
                ;;
            s)
                if [[ ! $command == "bump-api" ]]; then
                    error_usage "The option for squashing API version has no effect in this command mode."
                fi

                DO_SQUASH=true
                ;;
            t)
                if [[ $command == "package" ]]; then
                    error_usage "The option to set a version to bump to has no effect in this command mode."
                fi

                if [[ ! ${!OPTARG:0:1} == "-" ]]; then
                    ADDON_NEXT_VERSION="${OPTARG}";
                else
                    error_usage "Option -t requires a version."
                fi
                ;;
            :)
                error_usage "Option -${OPTARG} requires a value."
                ;;
            \?)
                error_usage "Unrecognized option provided: -${OPTARG}"
                ;;
        esac
    done
    shift $((OPTIND - 1))
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        bump)
            get_package_options "$@"
            bump_execute
            ;;
        bump-api)
            get_package_options "$@"
            bump_api_execute
            ;;
        -v|--version)
            echo "${PROGRAM_NAME} version ${PROGRAM_VERSION}"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            get_package_options "$@"
            package_execute
            ;;
    esac
else
    # Run default
    package_execute
fi

exit 0
