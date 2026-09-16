# Shared sshpass helper. Source after env.chicago.sh.
chicago_ssh() {
    sshpass -p "${CHICAGO_OLT_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=15 \
        "${CHICAGO_OLT_USER}@${CHICAGO_OLT_IP}" "$@"
}

chicago_scp() {
    sshpass -p "${CHICAGO_OLT_PASS}" scp \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=15 \
        "$@"
}
