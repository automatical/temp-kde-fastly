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
                    
                    # IMPORTANT: Network Manager relies on the following header
                    #            as part of it's "online" check.
                    #            Ref: https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/blob/c1d94d70814d1d28ef842c3d81357575d78df954/src/core/nm-connectivity.c#L536
                    set obj.http.X-NetworkManager-Status = "online";
                    synthetic {"OK"};
                    return(deliver);
                }
            }
        EOT
        main    = true
    }
}