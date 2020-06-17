#!/usr/bin/env bash

# https://github.com/jomo/imgur-screenshot
# https://imgur.com/tools

# Config Wiki
# https://github.com/jomo/imgur-screenshot/wiki/Config

###
# get version 2.0.0
###
#    $ git clone https://github.com/jomo/imgur-screenshot.git
#    $ git checkout cleanup

###
# MyRequiem Fork:
###
# https://github.com/MyRequiem/imgur-screenshot
#    $ git clone git@github.com:MyRequiem/imgur-screenshot.git
#    $ cd imgur-screenshot
#    $ git checkout min_edition

###
# Dependencies (from SBo):
###
#    1. imlib2
#    2. giblib
#    3. scrot
#    4. glm
#    5. slop
#    6. maim
#    7. xclip
#    8. oniguruma
#    9. jq

initialize() {
    declare -g -r CURRENT_VERSION="2.0.0"
    declare -r    CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

    if [ -f "${CONFIG_HOME}/user-dirs.dirs" ]; then
        source "${CONFIG_HOME}/user-dirs.dirs"
    fi

    declare -g -r CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/imgur-screenshot"
    declare -g -r SETTINGS_PATH="${CONFIG_DIR}/settings.conf"
    declare -g -a UPLOAD_FILES

    load_default_config

    if [ -f "${SETTINGS_PATH}" ]; then
        source "${SETTINGS_PATH}"
    fi

    ! [ -d "${FILE_DIR}" ] && mkdir -pv "${FILE_DIR}"
}

load_default_config() {
    declare -g CLIENT_ID="ea6c0ef2987808e"
    declare -g FILE_DIR="${XDG_PICTURES_DIR:-$HOME/Pictures}"
    declare -g FILE_NAME_FORMAT="imgur-%Y_%m_%d-%H:%M:%S.png"
    declare -g UPLOAD_CONNECT_TIMEOUT="5"
    declare -g UPLOAD_TIMEOUT="120"
    declare -g UPLOAD_RETRIES="1"
    declare -g SCREENSHOT_COMMAND="scrot -s %img"
    declare -g OPEN="true"
    declare -g OPEN_COMMAND="xdg-open %url"
    declare -g EDIT="false"
    declare -g EDIT_COMMAND="gimp %img"
    declare -g COPY_URL="true"
    declare -g CLIPBOARD_COMMAND="xclip -selection clipboard"
    declare -g LOG_FILE="${CONFIG_DIR}/imgur-screenshot.log"
    declare -g KEEP_FILE="true"
    declare -g AUTO_DELETE=""
    declare -g NOUPLOAD="false"
    declare -g CLEAR_FILE_DIR="false"
}

parse_args() {
    while [[ ${#} != 0 ]]; do
        case "${1}" in
            -h | --help)
                cat << EOF
Usage: $(echo "${0}" | rev | cut -d / -f 1 | rev) [option]... [file]...

Config: ${SETTINGS_PATH}

-h, --help                   show this message
-v, --version                show program version
-o, --open <true|false>      if set to true, open url after image uploaded
                                (override 'OPEN' config)
-e, --edit <true|false>      if set to true, make use of edit_command
                                (override 'EDIT' config)
-i, --edit-command <command> an executable that is run before the image is
                                uploaded. The image will be uploaded when the
                                program exits (override 'EDIT_COMMAND' config)
-k, --keep-file <true|false> if set to false, local file will be deleted
                                immediately after uploading to imgur
                                (override 'KEEP_FILE' config)
-d, --auto-delete <N>        automatically delete image after <N> seconds from
                                imgur server
-n, --noupload               do not upload the image to imgur, just take a
                                screenshot
-r, --clear                  clear directory where you want your images saved
file                         upload file instead of taking a screenshot
EOF
                exit 0;;
            -v | --version)
                echo "imgur-screenshot ${CURRENT_VERSION}"
                exit 0;;
            -o | --open)
                OPEN="${2}"
                shift 2;;
            -e | --edit)
                EDIT="${2}"
                shift 2;;
            -i | --edit-command)
                EDIT_COMMAND="${2}"
                EDIT="true"
                shift 2;;
            -k | --keep-file)
                KEEP_FILE="${2}"
                shift 2;;
            -d | --auto-delete)
                AUTO_DELETE="${2}"
                shift 2;;
            -n | --noupload)
                NOUPLOAD="true"
                KEEP_FILE="true"
                shift 1;;
            -r | --clear)
                CLEAR_FILE_DIR="true"
                shift 1;;
            *)
                UPLOAD_FILES=("${@}")
                break;;
        esac
    done
}

check_config() {
    local vars
    vars=(CLIENT_ID FILE_DIR FILE_NAME_FORMAT UPLOAD_CONNECT_TIMEOUT)
    vars+=(UPLOAD_TIMEOUT UPLOAD_RETRIES LOG_FILE)

    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Config option $var is not set"
            exit 1
        fi
    done
}

main() {
    # checks presence of essential config options
    check_config

    if [ -z "${UPLOAD_FILES[0]}" ]; then
        # force one screenshot to be taken if no files provided
        UPLOAD_FILES[0]=""
    fi

    for upload_file in "${UPLOAD_FILES[@]}"; do
        handle_file "${upload_file}"
    done
}

take_screenshot() {
    local cmd shot_err

    echo -e  "Please select area ...\n"
    # https://bbs.archlinux.org/viewtopic.php?pid=1246173#p1246173
    sleep 0.2

    cmd="SCREENSHOT_COMMAND"
    cmd=${!cmd//\%img/${1}}

    if [ -z "${cmd}" ]; then
        echo "Warning: SCREENSHOT_COMMAND is empty"
        cmd=false
    fi

    shot_err="$(${cmd} &>/dev/null)"
    if [ "${?}" != "0" ]; then
        {
            [ -n "${shot_err}" ] && shot_err=" -- Error: ${shot_err}"
            echo -n "[$(date +"%d.%m.%y %H:%M:%S")] "
            echo "Failed to take screenshot ${1}${shot_err}"
        } | tee -a "${LOG_FILE}"

        exit 1
    fi
}

delete_image() {
    local response

    response="$(curl                           \
        --compressed                           \
        -X DELETE                              \
        -fsSL --stderr -                       \
        -H "Authorization: Client-ID ${1}"     \
        "https://api.imgur.com/3/image/${2}")"

    if [ "${?}" -eq "0" ] && \
            [[ "$(jq -r .success <<<"${response}")" == "true" ]]; then
        {
            echo -en "[$(date +"%d.%m.%y %H:%M:%S")]\n\t"
            echo "Image "${4}" successfully deleted (delete hash: ${2})"
        } | tee -a "${3}"
    else
        {
            echo -en "[$(date +"%d.%m.%y %H:%M:%S")]\n\t"
            echo "The Image "${4}" could not be deleted: ${response}"
        } | tee -a "${3}"
    fi
}

handle_file() {
    local img_file edit_cmd

    if [ -z "${1}" ]; then
        # take screenshot
        cd "${FILE_DIR}" || exit 1

        [[ ${CLEAR_FILE_DIR} == "true" ]] && rm -f *.png

        # new filename with date
        img_file="$(date +"${FILE_NAME_FORMAT}")"
        take_screenshot "${img_file}"
    else
        # upload file instead of screenshot

        NOUPLOAD="false"
        img_file="${1}"
    fi

    # check if file exists
    if ! [ -f "${img_file}" ]; then
        echo "File '${1}' not found"
        exit 1
    fi

    # get full path
    img_file="$(cd "$(dirname "${img_file}")" && \
        echo "$(pwd)/$(basename "${img_file}")")"

    # open image in editor if configured
    if [[ "${EDIT}" == "true" ]]; then
        edit_cmd=${EDIT_COMMAND//\%img/${img_file}}
        echo "Opening editor ${edit_cmd} ..."
        if ! (eval "${edit_cmd}"); then
            {
                echo -n "[$(date +"%d.%m.%y %H:%M:%S")] Error: "
                echo "command '${edit_cmd}' failed, not uploading"
            } | tee -a "${LOG_FILE}"
            exit 1
        fi
    fi

    if [[ "${NOUPLOAD}" == "false" ]]; then
        upload_image "${img_file}"
    fi

    # delete file if configured
    if [ "${KEEP_FILE}" = "false" ] && [ -z "${1}" ]; then
        echo "Deleting temp file ${FILE_DIR}/${img_file}"
        rm -f "${img_file}"
    fi

    echo ""
}

upload_image() {
    local title authorization response img_path del_id err_msg

    echo "Uploading ${1} ..."

    title="$(echo "${1}" | rev | cut -d "/" -f 1 | cut -d "." -f 2- | rev)"
    authorization="Client-ID ${CLIENT_ID}"

    response="$(curl                                  \
        --compressed                                  \
        --connect-timeout "${UPLOAD_CONNECT_TIMEOUT}" \
        -m "${UPLOAD_TIMEOUT}"                        \
        --retry "${UPLOAD_RETRIES}"                   \
        -fsSL --stderr -                              \
        -H "Authorization: ${authorization}"          \
        -F "title=${title}"                           \
        -F "image=@\"${1}\""                          \
        https://api.imgur.com/3/image)"

    if [[ "$(jq -r .success <<<"${response}" 2>/dev/null)" == "true" ]]; then
        img_path="$(jq -r .data.link <<<"${response}" | cut -d / -f 3-)"
        del_id="$(jq -r .data.deletehash <<<"${response}")"

        if [ -n "${AUTO_DELETE}" ]; then
            export -f delete_image
            echo "Deleting image in ${AUTO_DELETE} seconds"
            nohup /bin/bash -c "sleep ${AUTO_DELETE} && \
                delete_image             \
                    ${CLIENT_ID}         \
                    ${del_id}            \
                    ${LOG_FILE}          \
                    https://${img_path}" &
        fi

        handle_upload_success                    \
            "https://${img_path}"                \
            "https://imgur.com/delete/${del_id}" \
            "${1}"
    else # upload failed
        err_msg="$(jq .error <<<"${response}" 2>/dev/null)"
        [ -z "${err_msg}" ] && err_msg="${response}"
        handle_upload_error \
            "${err_msg}"    \
            "${1}"
    fi
}

handle_upload_success() {
    local open_cmd

    echo ""
    echo "Image  link: ${1}"
    echo "Delete link: ${2}"

    if [[ "${COPY_URL}" = "true" ]]; then
        echo -n "${1}" | eval "${CLIPBOARD_COMMAND}"
        echo "URL copied to clipboard"
    fi

    # print to log file: image link, image location, delete link
    {
        echo -en "[$(date +"%d.%m.%y %H:%M:%S")]\n\tImage  link: ${1}\n\t"
        echo "Delete link: ${2}"
    } >> "${LOG_FILE}"

    if [ -n "${OPEN_COMMAND}" ] && [[ "${OPEN}" == "true" ]]; then
        open_cmd=${OPEN_COMMAND//\%url/${1}}
        open_cmd=${open_cmd//\%img/${2}}
        echo "Opening '${open_cmd}'"
        eval "${open_cmd}"
    fi
}

handle_upload_error() {
    local error

    error="Upload failed: \"${1}\""
    echo "${error}"
    {
        echo -en "[$(date +"%d.%m.%y %H:%M:%S")]\n\t"
        echo "Upload error: ${2}\n\t${error}"
    } >> "${LOG_FILE}"
}

initialize
parse_args "${@}"
main
