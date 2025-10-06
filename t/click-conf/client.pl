{
    openSSL => {
        client => {
            loadDefaultCAFile => 'true',
            cacheSessions => 'true',
            disableProtocols => 'sslv2,sslv3',
            preferServerCiphers => 'true',
            invalidCertificateHandler => {
                name => 'RejectCertificateHandler',
            },
        },
    },
    prompt_by_server_display_name => {
        default => '{display_name}',
        test => '\e[1;32m{display_name}\e[0m',
        production => '\e[1;31m{display_name}\e[0m',
    },
    google_protos_path => '/usr/share/clickhouse/protos/',
}
