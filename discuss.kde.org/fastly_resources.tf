resource "fastly_service_vcl" "discuss_kde_org" {
    name = "discuss.kde.org"

    domain {
        name = "discuss.kde.org"
    }

    # Discourse holds MessageBus long-polls open for about 25s, so
    # first_byte_timeout is set well above that.
    #
    # cinclo's certificate only covers discuss.kde.org, so Fastly connects
    # to cinclo but sends and checks discuss.kde.org as the TLS name.
    backend {
        address               = "cinclo.kde.org"
        name                  = "cinclo_kde_org"
        port                  = 443
        use_ssl               = true
        ssl_cert_hostname     = "discuss.kde.org"
        ssl_sni_hostname      = "discuss.kde.org"
        auto_loadbalance      = false
        connect_timeout       = 5000
        first_byte_timeout    = 60000
        between_bytes_timeout = 10000
    }

    # One edge dictionary per blocklist in dictionaries.tf.
    dynamic "dictionary" {
        for_each = local.blocklists
        content {
            name          = dictionary.key
            force_destroy = true
        }
    }

    logging_s3 {
        name              = "s3_access_logs"
        domain            = var.s3_endpoint
        bucket_name       = var.s3_bucket_name
        s3_access_key     = var.s3_access_key
        s3_secret_key     = var.s3_secret_key
        path              = var.s3_path
        period            = var.log_period
        compression_codec = "gzip"
        format_version    = 2
        message_type      = "blank"
        # log_format.json is laid out for readability; Fastly wants one
        # line per log entry, so remove the newlines and indentation.
        format            = replace(file("${path.module}/log_format.json"), "/\\n\\s*/", "")
    }

    vcl {
        name    = "main"
        content = <<-EOT
            sub vcl_recv {
                #FASTLY recv

                # Clients must not be able to set these headers themselves.
                unset req.http.X-Blocklist-Match;
                unset req.http.X-Blocklist-Action;

                # Fingerprinting headers. They are used for blocklist lookups
                # and logging, and are also sent to the origin.
                set req.http.X-JA3 = tls.client.ja3_md5;
                set req.http.X-JA4 = tls.client.ja4;
                # Fastly doesn't document a VCL variable for the HTTP/2
                # fingerprint, so this reads the header the other KDE
                # services use. If the header isn't set, H2 matching and
                # logging are no-ops.
                set req.http.X-H2-Fingerprint = req.http.Fastly-Client-H2-Fingerprint;
                set req.http.X-ASN = client.as.name;
                set req.http.X-ASN-Number = client.as.number;

                if (req.restarts == 0) {
                    declare local var.hit STRING;

                    if (req.http.X-JA3) {
                        set var.hit = table.lookup(blocklist_ja3, req.http.X-JA3, "");
                        if (var.hit != "") {
                            set req.http.X-Blocklist-Match = if(req.http.X-Blocklist-Match, req.http.X-Blocklist-Match ",ja3", "ja3");
                            if (var.hit != "log") { set req.http.X-Blocklist-Action = "block"; }
                        }
                    }

                    if (req.http.X-JA4) {
                        set var.hit = table.lookup(blocklist_ja4, req.http.X-JA4, "");
                        if (var.hit != "") {
                            set req.http.X-Blocklist-Match = if(req.http.X-Blocklist-Match, req.http.X-Blocklist-Match ",ja4", "ja4");
                            if (var.hit != "log") { set req.http.X-Blocklist-Action = "block"; }
                        }
                    }

                    if (req.http.X-H2-Fingerprint) {
                        set var.hit = table.lookup(blocklist_h2, req.http.X-H2-Fingerprint, "");
                        if (var.hit != "") {
                            set req.http.X-Blocklist-Match = if(req.http.X-Blocklist-Match, req.http.X-Blocklist-Match ",h2", "h2");
                            if (var.hit != "log") { set req.http.X-Blocklist-Action = "block"; }
                        }
                    }

                    if (req.http.X-ASN-Number) {
                        set var.hit = table.lookup(blocklist_asn, req.http.X-ASN-Number, "");
                        if (var.hit != "") {
                            set req.http.X-Blocklist-Match = if(req.http.X-Blocklist-Match, req.http.X-Blocklist-Match ",asn", "asn");
                            if (var.hit != "log") { set req.http.X-Blocklist-Action = "block"; }
                        }
                    }

                    if (req.http.User-Agent) {
                        set var.hit = table.lookup(blocklist_user_agent, req.http.User-Agent, "");
                        if (var.hit != "") {
                            set req.http.X-Blocklist-Match = if(req.http.X-Blocklist-Match, req.http.X-Blocklist-Match ",user_agent", "user_agent");
                            if (var.hit != "log") { set req.http.X-Blocklist-Action = "block"; }
                        }
                    }

                    if (req.http.X-Blocklist-Match && !req.http.X-Blocklist-Action) {
                        set req.http.X-Blocklist-Action = "log";
                    }

                    if (req.http.X-Blocklist-Action == "block") {
                        error 403 "Forbidden";
                    }
                }

                return(pass);
            }

            sub vcl_error {
                #FASTLY error

                if (obj.status == 403 && req.http.X-Blocklist-Action == "block") {
                    set obj.http.Content-Type = "text/plain; charset=utf-8";
                    set obj.http.Cache-Control = "no-store";
                    synthetic {"Access denied. If you believe this is a mistake, please quote this reference: "} req.xid;
                    return(deliver);
                }
            }

            sub vcl_deliver {
                #FASTLY deliver
                return(deliver);
            }

            sub vcl_log {
                #FASTLY log
            }
        EOT
        main    = true
    }

    force_destroy = true
}
