#!/bin/zsh
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
identity_file="$project_dir/.local/signing-identity"
identity_choice="${EASYPIC_SIGN_IDENTITY:-}"
if [[ -z "$identity_choice" && -f "$identity_file" ]]; then
    identity_choice="$(cat "$identity_file")"
fi
identities="$(security find-identity -v -p codesigning)"

if [[ "$identity_choice" == "-" ]]; then
    print -r -- "-"
    exit 0
fi

if [[ -n "$identity_choice" ]]; then
    matches="$(print -r -- "$identities" | awk -v choice="$identity_choice" '
        /^[[:space:]]*[0-9]+\)/ {
            fingerprint = $2
            name = $0
            sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
            if (fingerprint == choice || name == choice) print fingerprint
        }')"
else
    # Select a single Apple identity, then keep using it across future builds.
    matches="$(print -r -- "$identities" | awk '
        /^[[:space:]]*[0-9]+\)/ && /"(Apple Development:|Developer ID Application:|Mac Developer:)/ { print $2 }')"
fi

if [[ -z "$matches" ]]; then
    if [[ -n "$identity_choice" ]]; then
        echo "指定的签名证书不可用。请检查钥匙串中的证书及私钥，或更新 .local/signing-identity。" >&2
        exit 1
    fi
    echo "当前没有开发签名证书，使用临时签名；更新后 macOS 可能重新询问文件夹权限。" >&2
    print -r -- "-"
    exit 0
fi

match_lines=(${(f)matches})
if (( ${#match_lines} != 1 )); then
    echo "有多个可用签名证书，请用 EASYPIC_SIGN_IDENTITY 指定证书名称或 SHA-1 指纹。" >&2
    exit 1
fi
if [[ -z "${EASYPIC_SIGN_IDENTITY:-}" && ! -f "$identity_file" ]]; then
    mkdir -p "$project_dir/.local"
    print -r -- "$matches" > "$identity_file"
fi
print -r -- "$matches"
