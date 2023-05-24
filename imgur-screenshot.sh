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
#    10. zenity
#    11. flameshot

initialize() {
    declare -g -r SETTINGS_PATH="${HOME}/.config/imgur-screenshot/settings.conf"
    declare -g -a UPLOAD_FILES

    load_default_config

    [ -f "${SETTINGS_PATH}" ] && source "${SETTINGS_PATH}"
    ! [ -d "${FILE_DIR}" ] && mkdir -pv "${FILE_DIR}"
}

load_default_config() {
    declare -g UPLOAD_TOOL="curl"
    declare -g IMGBB_API_KEY="fc66ee854276e589f5827656a0753b63"
    declare -g CLIENT_ID="ea6c0ef2987808e"
    declare -g FILE_DIR="${HOME}/tmp/_screenshots"
    declare -g FILE_NAME_FORMAT="imgur-%Y_%m_%d-%H:%M:%S.png"
    declare -g UPLOAD_CONNECT_TIMEOUT="5"
    declare -g UPLOAD_TIMEOUT="120"
    declare -g UPLOAD_RETRIES="1"
    declare -g SCREENSHOT_COMMAND="scrot -s %img"
    declare -g COPY_URL="true"
    declare -g CLIPBOARD_COMMAND="xclip -selection clipboard"
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
-n, --noupload               do not upload the image to imgur, just take a
                                screenshot
-r, --clear                  clear directory where you want your images saved
--timeout=N                  delay (in seconds) before taking a screenshot
                                (only for maim, not scrot)
file                         upload file instead of taking a screenshot
EOF
                exit 0;;
            -n | --noupload)
                NOUPLOAD="true"
                shift 1;;
            -r | --clear)
                CLEAR_FILE_DIR="true"
                shift 1;;
            --timeout=*)
                if [[ ${SCREENSHOT_COMMAND} =~ maim ]]; then
                    SEC="$(echo "${1}" | cut -d = -f 2)"
                    SCREENSHOT_COMMAND="${SCREENSHOT_COMMAND} --delay=${SEC}"
                    unset SEC
                else
                    echo -n "To use a timeout, use utility 'maim' instead of "
                    echo -en "'scrot'\nSee SCREENSHOT_COMMAND variable in "
                    echo "${SETTINGS_PATH}"
                    exit 1
                fi
                shift 1;;
            *)
                UPLOAD_FILES=("${@}")
                break;;
        esac
    done
}

main() {
    if [ -z "${UPLOAD_FILES[0]}" ]; then
        # force one screenshot to be taken if no files provided
        UPLOAD_FILES[0]=""
    fi

    for upload_file in "${UPLOAD_FILES[@]}"; do
        handle_file "${upload_file}"
    done
}

take_screenshot() {
    echo -e  "Please select area ...\n"
    # https://bbs.archlinux.org/viewtopic.php?pid=1246173#p1246173
    sleep 0.2

    local cmd
    cmd="SCREENSHOT_COMMAND"
    cmd=${!cmd//\%img/${1}}
    "$(${cmd} &>/dev/null)"
}

handle_file() {
    local img_file

    if [ -z "${1}" ]; then
        # take screenshot
        cd "${FILE_DIR}" || exit 1

        if [[ ${CLEAR_FILE_DIR} == "true" ]]; then
            mkdir -p .removed
            find . -type f -maxdepth 1 -exec mv {} .removed/ \;
        fi

        if [[ "${NOUPLOAD}" == "false" && \
            "${UPLOAD_TOOL}" == "flameshot" ]]; then
            "${UPLOAD_TOOL}" gui
            return
        fi

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

    if [[ "${NOUPLOAD}" == "false" ]]; then
        upload_image "${img_file}"
    fi

    echo ""
}

upload_image() {
    local title authorization response img_link err_msg

    echo "Uploading ${1} ..."

    title="$(echo "${1}" | rev | cut -d "/" -f 1 | cut -d "." -f 2- | rev)"
    authorization="Client-ID ${CLIENT_ID}"

    if [[ "${UPLOAD_TOOL}" == "imgbb" ]]; then
        # удалять через 14 дней (в секундах)
        EXPIRATION=1209600
        API_URL="https://api.imgbb.com/1/upload"
        REQUEST="${API_URL}?expiration=${EXPIRATION}&key=${IMGBB_API_KEY}"
        response=$(curl                 \
            --silent                    \
            --location                  \
            --request POST "${REQUEST}" \
            --form "image=@$1"          \
        )
    else
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
    fi

    if [[ "$(jq -r .success <<<"${response}" 2>/dev/null)" == "true" ]]; then
        if [[ "${UPLOAD_TOOL}" == "imgbb" ]]; then
            img_link="$(jq -r .data.url_viewer <<< "${response}")"
        else
            img_link="$(jq -r .data.link <<< "${response}" | cut -d / -f 3-)"
            img_link="https://${img_link}"
        fi
# echo $img_link; exit
        handle_upload_success "${img_link}"
    else # upload failed
        err_msg="$(jq .error <<<"${response}" 2>/dev/null)"
        [ -z "${err_msg}" ] && err_msg="${response}"
        handle_upload_error \
            "${err_msg}"    \
            "${1}"
    fi
}

show_upload_result_message() {
    TITLE="Imgur Screenshot"
    if [ $1 -eq 0 ]; then
        MESS="Screenshot uploaded successfully. \
Link copied to clipboard. \n${2}"
        zenity --info --title="${TITLE}" --text="${MESS}"
    else
        MESS="Screenshot uploading ERROR!!!"
        zenity --error --title="${TITLE}" --text="${MESS}"
    fi
}

handle_upload_success() {
    local open_cmd

    echo ""
    echo "Image  link: ${1}"

    if [[ "${COPY_URL}" = "true" ]]; then
        echo -n "${1}" | eval "${CLIPBOARD_COMMAND}"
        echo "URL copied to clipboard"
    fi

    show_upload_result_message 0 "${1}"
}

handle_upload_error() {
    local error
    error="Upload failed: \"${1}\""
    show_upload_result_message 1
}

initialize
parse_args "${@}"
main
