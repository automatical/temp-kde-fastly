resource "fastly_service_vcl" "networkcheck" {
    name = "networkcheck.kde.org"

    domain {
        name = "networkcheck.kde.org"
    }

    backend {
        address = "127.0.0.1"
        name    = "localhost"
        port    = 80
    }

    force_destroy = true

    vcl {
        name    = "main"
        content = <<-EOT
            sub vcl_recv {
                error 601;
            }

            sub vcl_error {
                if (obj.status == 601) {
                    set obj.status = 200;
                    set obj.response = "OK";
                    set obj.http.Content-Type = "text/html";
                    set obj.http.X-NetworkManager-Status = "online";
                    synthetic {"OK"};
                    return(deliver);
                }
            }
        EOT
        main    = true
    }
}