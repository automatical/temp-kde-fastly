# Blockable fingerprints for discuss.kde.org.
#
# Each map below becomes a Fastly edge dictionary with the same name, and
# vcl_recv in fastly_resources.tf looks each request up in it.
#
#   key   = the fingerprint to match (exact match)
#   value = "log"  -> record the match in the access logs, let the request through
#           any other value (use "block") -> return 403
#
# Use "log" first to check a new entry for false positives, then switch it
# to "block". Put the reason for each entry in a comment beside it.
#
# Terraform owns these items (manage_items = true): entries added outside
# Terraform are removed on the next apply.

locals {
    blocklists = {
        # tls.client.ja3_md5, e.g. "e7d705a3286e19ea42f587b344ee6865"
        blocklist_ja3 = {
        }

        # tls.client.ja4, e.g. "t13d1516h2_8daaf6152771_02713d6af862"
        blocklist_ja4 = {
        }

        # HTTP/2 fingerprint (Akamai format),
        # e.g. "1:65536;2:0;4:6291456;6:262144|15663105|0|m,a,s,p"
        blocklist_h2 = {
        }

        # Autonomous System Number as a decimal string, e.g. "64496"
        blocklist_asn = {
        }

        # Exact User-Agent header value
        blocklist_user_agent = {
        }
    }
}

resource "fastly_service_dictionary_items" "blocklists" {
    for_each = {
        for d in fastly_service_vcl.discuss_kde_org.dictionary : d.name => d
        if contains(keys(local.blocklists), d.name)
    }

    service_id    = fastly_service_vcl.discuss_kde_org.id
    dictionary_id = each.value.dictionary_id
    items         = local.blocklists[each.key]
    manage_items  = true
}
