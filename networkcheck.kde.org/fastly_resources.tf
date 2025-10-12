resource "fastly_service_vcl" "networkcheck" {
    name = "networkcheck.kde.org"

    domain {
        name = "networkcheck.kde.org"
    }

    backend {
        address = "localhost"
        name    = "localhost"
        port    = 80
    }

    force_destroy = true

    vcl {
        name    = "main"
        content = <<-EOT
            sub vcl_recv {
                return (synth(200, "OK"));
            }

            sub vcl_synth {
                if (resp.status == 200) {
                    set resp.http.Content-Type = "text/plain";
                    synthetic("OK");
                    return (deliver);
                }
            }
        EOT
        main    = true
    }
}