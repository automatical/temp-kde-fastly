resource "fastly_service_vcl" "websvn_kde_org" {
    name = "websvn.kde.org"

    domain {
        name = "websvn.kde.org"
    }

    backend {
        address               = "phasia.kde.org"
        name                  = "phasia_kde_org"
        port                  = 443
        use_ssl               = true
        ssl_cert_hostname     = "phasia.kde.org"
        ssl_sni_hostname      = "phasia.kde.org"
        auto_loadbalance      = false
        connect_timeout       = 5000
        first_byte_timeout    = 15000
        between_bytes_timeout = 10000
    }

    vcl {
        name    = "main"
        content = <<-EOT
            sub vcl_recv {
                #FASTLY recv

                # Add fingerprinting headers
                if (req.http.Fastly-Client-JA3) {
                    set req.http.X-JA3 = req.http.Fastly-Client-JA3;
                }
                
                if (req.http.Fastly-Client-JA4) {
                    set req.http.X-JA4 = req.http.Fastly-Client-JA4;
                }
                
                if (req.http.Fastly-Client-H2-Fingerprint) {
                    set req.http.X-H2-Fingerprint = req.http.Fastly-Client-H2-Fingerprint;
                }
                
                if (client.as.name) {
                    set req.http.X-ASN = client.as.name;
                }

                return(pass);
            }

            sub vcl_deliver {
                #FASTLY deliver
                return(deliver);
            }
        EOT
        main    = true
    }

    force_destroy = true
}