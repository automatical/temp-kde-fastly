resource "fastly_service_vcl" "identity_kde_org" {
    name = "identity.kde.org"

    domain {
        name = "identity.kde.org"
    }

    backend {
        address               = "aranea.kde.org"
        name                  = "aranea_kde_org"
        port                  = 443
        use_ssl               = true
        ssl_cert_hostname     = "aranea.kde.org"
        ssl_sni_hostname      = "aranea.kde.org"
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