# discuss.kde.org

Fastly service in front of discuss.kde.org (Discourse). The origin is
`cinclo.kde.org` over TLS.

## Files

| File | Purpose |
|---|---|
| `fastly_resources.tf` | The service: domain, backend, dictionaries, S3 logging, VCL |
| `dictionaries.tf` | Blocklist contents, one map per dictionary |
| `log_format.json` | Log line format (Fastly format version 2) |
| `variables.tf` | S3 endpoint, bucket, credentials, path, upload period |
| `terraform.tfvars.example` | Sample values. Copy it to `terraform.tfvars` (git-ignored) or use `TF_VAR_*` env vars |

## How it works

### Request flow

Every request is passed to the origin; Fastly caches nothing. On each request,
`vcl_recv`:

1. Removes any `X-Blocklist-Match` / `X-Blocklist-Action` headers the client
   sent, so clients can't fake these log fields.
2. Sets these fingerprint headers. They are sent on to the origin as well:

   | Header | Source |
   |---|---|
   | `X-JA3` | `tls.client.ja3_md5` |
   | `X-JA4` | `tls.client.ja4` |
   | `X-H2-Fingerprint` | `Fastly-Client-H2-Fingerprint` request header (see note below) |
   | `X-ASN` | `client.as.name` |
   | `X-ASN-Number` | `client.as.number` |

3. Looks each value up in the matching blocklist dictionary (first pass only,
   not on restarts).
4. Returns a `403` if any entry that matched is set to block. The 403 page
   includes the request ID (`req.xid`); search the logs for it when someone
   reports being blocked by mistake.

Fastly connects to `cinclo.kde.org` but uses `discuss.kde.org` as the TLS
name (`ssl_cert_hostname` / `ssl_sni_hostname`), because cinclo's certificate
only covers `discuss.kde.org`. If these are set to `cinclo.kde.org`, Fastly
returns `503 hostname doesn't match against certificate`. If cinclo's
certificate ever changes, check which names it covers:

```sh
echo | openssl s_client -connect cinclo.kde.org:443 -servername discuss.kde.org 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName -enddate
```

The backend's `first_byte_timeout` is 60s. Discourse's MessageBus holds
requests open for about 25s, and the 15s used by other KDE services would cut
them off.

> **HTTP/2 fingerprint:** Fastly doesn't document a VCL variable for the
> HTTP/2 fingerprint, so the VCL reads the `Fastly-Client-H2-Fingerprint`
> header instead. If Fastly doesn't set that header, `h2_fingerprint` stays
> empty in the logs and `blocklist_h2` never matches. Check the logs to
> confirm.

### Blocklists

There is one dictionary per fingerprint type, defined in `dictionaries.tf`:

| Dictionary | Key |
|---|---|
| `blocklist_ja3` | JA3 MD5 hash |
| `blocklist_ja4` | JA4 string |
| `blocklist_h2` | HTTP/2 fingerprint (Akamai format) |
| `blocklist_asn` | AS number as a decimal string, e.g. `"64496"` |
| `blocklist_user_agent` | Exact `User-Agent` value |

What an entry's value does:

- `"log"`: the match is recorded in the logs (`blocklist_match`,
  `blocklist_action = "log"`) and the request goes through.
- Anything else (use `"block"`): the request gets a 403.

If several lists match, `blocklist_match` names all of them (e.g. `ja4,asn`).
A single `block` match is enough to block the request.

Add new entries as `"log"` first, check the logs for false positives, then
change them to `"block"`. Put the reason for each entry in a comment next to
it:

```hcl
blocklist_ja4 = {
    "t13d1516h2_8daaf6152771_02713d6af862" = "block" # scraper, 2026-11-15
}
```

The dictionaries are managed by Terraform (`manage_items = true`). Entries
added through the Fastly UI or API are removed on the next `terraform apply`.

### Logging

Logs go to an S3-compatible bucket:

- Format: one JSON object per line, gzipped
- Upload frequency: every `log_period` seconds (default 300)
- Location: under `s3_path` (default `/discuss.kde.org/%Y/%m/%d/`)

`log_format.json` is written over several lines so it's easy to read.
Terraform joins it onto one line before sending it to Fastly. If you edit it,
keep string values inside `"%{json.escape(...)}V"` so the output stays valid
JSON.

Fields logged:

- **Request:** timestamp, request ID, POP, cache state, elapsed time, method,
  host, URL, protocol, H2/H3 flags, status, bytes in and out, content type
- **Client:** client IP, `X-Forwarded-For`
- **Geo:** continent, country, region, city, postal code, latitude/longitude,
  connection type, proxy type and description
- **ASN:** number and name
- **TLS:** protocol, cipher, SNI, JA3, JA4, HTTP/2 fingerprint
- **Blocklist:** `blocklist_match`, `blocklist_action`
- **Headers:** User-Agent, Referer, Origin, Accept, Accept-Language,
  Accept-Encoding, all `Sec-CH-UA*` and `Sec-Fetch-*` headers

The detailed client hints (`Sec-CH-UA-Platform-Version`, `-Arch`, `-Model`,
`-Full-Version-List`) are only sent by browsers if the site asks for them with
an `Accept-CH` response header. Nothing sets that header at the moment, so
these fields are usually empty.

## Deploying

```sh
export FASTLY_API_KEY=...
cp terraform.tfvars.example terraform.tfvars   # fill in S3 details
terraform init
terraform apply
```

This repo uses 4-space indentation, so don't run `terraform fmt`; it would
reformat the files.

## Testing before the DNS change

Until DNS is switched, discuss.kde.org resolves straight to cinclo. To test,
send requests to Fastly directly while keeping the `discuss.kde.org` hostname.

### 1. HTTP smoke test (no certificate needed)

```sh
FASTLY_IP=$(dig +short nonssl.global.fastly.net | tail -1)
curl -sv -o /dev/null -H 'Fastly-Debug: 1' \
  --resolve discuss.kde.org:80:$FASTLY_IP http://discuss.kde.org/
```

The response should include `x-served-by: cache-…` and a `via` header
mentioning varnish. A 301 redirect to https from Discourse is fine; it means
the origin answered. There is no TLS handshake over HTTP, so JA3 and JA4 will
be empty for this request.

### 2. HTTPS

Create a Fastly TLS subscription for `discuss.kde.org`. Validating it only
needs an `_acme-challenge.discuss.kde.org` CNAME, so the live record isn't
touched. Fastly then gives you a hostname to point DNS at. Use that hostname
now:

```sh
curl -sv -H 'Fastly-Debug: 1' \
  --connect-to discuss.kde.org:443:<fastly-tls-hostname>:443 \
  https://discuss.kde.org/
```

`--connect-to` keeps the SNI and Host as `discuss.kde.org`, so the request
looks exactly like it will after the DNS change. If the certificate isn't
issued yet, add `-k`; JA3 and JA4 are still captured.

### 3. In a browser

Add `<IP of fastly-tls-hostname> discuss.kde.org` to `/etc/hosts`, then test
the site properly:

- Log in and post. This checks that cookies and CSRF work through Fastly.
- Upload an image.
- Leave a topic open and post a reply from another session. The reply should
  appear without a refresh; this exercises the 60s timeout.

Remove the hosts entry afterwards.

### 4. Logs

Within about `log_period` seconds, files should appear in the bucket:

```sh
aws s3 cp --endpoint-url https://<endpoint> s3://<bucket>/<key> - \
  | gunzip | head -1 | jq .
```

Check that:

- every line parses as JSON
- `ja3`, `ja4`, `asn` and the `geo_*` fields are filled in
- `h2_fingerprint` is filled in for HTTP/2 requests. If it is empty, see the
  HTTP/2 fingerprint note above.

If no files appear, look for the S3 endpoint's error in the logging section of
the Fastly UI.

### 5. Blocklist

Test with curl rather than your browser. curl has a different fingerprint, so
your browser keeps working.

1. Take curl's `ja4` value from the logs.
2. Add it to `blocklist_ja4` as `"log"` and apply. The logs should show
   `blocklist_match: "ja4"` and `blocklist_action: "log"`.
3. Change it to `"block"` and apply. curl should get a 403 with a reference
   ID; the browser should still work.
4. Remove the entry and apply.

### 6. Real client IPs

In the Discourse admin, check that your session shows your own IP, not a
Fastly address. If it shows a Fastly address, configure Discourse on cinclo to
trust `X-Forwarded-For` from Fastly's IP ranges.

## Useful curl commands

Until DNS is switched, use this helper so requests go through Fastly while
keeping the `discuss.kde.org` hostname. Add `-k` to the commands below if the
Fastly certificate hasn't been issued yet.

```sh
FASTLY_HOST=<fastly-tls-hostname>
fcurl() { curl --connect-to "discuss.kde.org:443:${FASTLY_HOST}:443" "$@"; }
```

After the cutover, use plain `curl` instead of `fcurl`.

### Confirm the request went through Fastly

```sh
fcurl -s -o /dev/null -D - -H 'Fastly-Debug: 1' https://discuss.kde.org/
```

The response headers should include `x-served-by: cache-…` and
`fastly-debug-path`. If you see neither, the request went straight to cinclo.

### Check the certificate Fastly serves

```sh
fcurl -sv -o /dev/null https://discuss.kde.org/ 2>&1 \
  | grep -E 'subject:|issuer:|expire date:|SSL connection'
```

### Compare timing: Fastly vs origin

```sh
FMT='dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} http=%{http_version} status=%{http_code}\n'

# Through Fastly
fcurl -s -o /dev/null -w "$FMT" https://discuss.kde.org/

# Straight to the origin, with the same Host and SNI
curl -s -o /dev/null -w "$FMT" \
  --connect-to discuss.kde.org:443:cinclo.kde.org:443 https://discuss.kde.org/
```

### Produce different fingerprints

Each of these requests produces a different JA3/JA4 and protocol in the logs.
They're useful for checking that the fields are filled in, and for creating a
fingerprint to test the blocklist with.

```sh
fcurl -s -o /dev/null -w '%{http_version}\n' --http2   https://discuss.kde.org/
fcurl -s -o /dev/null -w '%{http_version}\n' --http1.1 https://discuss.kde.org/
fcurl -s -o /dev/null --tlsv1.2 --tls-max 1.2          https://discuss.kde.org/
fcurl -s -o /dev/null --tlsv1.3                        https://discuss.kde.org/
```

`h2_fingerprint` should only be filled in for the `--http2` request.

### Send client hints and Sec-Fetch headers

Browsers only send the detailed client hints when asked, so set them by hand
to check they appear in the logs:

```sh
fcurl -s -o /dev/null https://discuss.kde.org/ \
  -H 'Sec-CH-UA: "Chromium";v="130", "Not?A_Brand";v="99"' \
  -H 'Sec-CH-UA-Mobile: ?0' \
  -H 'Sec-CH-UA-Platform: "Linux"' \
  -H 'Sec-CH-UA-Platform-Version: "6.11.0"' \
  -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Mode: navigate' \
  -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-User: ?1'
```

The quotes inside `Sec-CH-UA` should show up escaped in the JSON log line,
and the line should still parse.

### Test the User-Agent blocklist

Pick a UA string nobody uses, so a test entry can't block real users:

```sh
fcurl -s -A 'kde-fastly-blocklist-test/1.0' -o /dev/null -w '%{http_code}\n' \
  https://discuss.kde.org/
```

1. With no entry, this returns 200 (or a Discourse redirect).
2. Add `"kde-fastly-blocklist-test/1.0" = "log"` to `blocklist_user_agent` and
   apply. It still returns 200, and the log line shows
   `blocklist_match: "user_agent"` and `blocklist_action: "log"`.
3. Change the value to `"block"` and apply. It returns 403. See the reference
   ID with:

   ```sh
   fcurl -s -A 'kde-fastly-blocklist-test/1.0' https://discuss.kde.org/
   ```

4. Remove the entry and apply.

### Check that clients can't fake blocklist headers

```sh
fcurl -s -o /dev/null -w '%{http_code}\n' https://discuss.kde.org/ \
  -H 'X-Blocklist-Action: block' -H 'X-Blocklist-Match: ja4'
```

This should return 200 rather than 403, and the log line must not contain the
`block` / `ja4` values you sent.

### Check how long requests can stay open

Requests that take longer than the 60s `first_byte_timeout` fail with a Fastly
`503`. To see how long a slow page actually takes through Fastly:

```sh
fcurl -s -o /dev/null -w 'status=%{http_code} ttfb=%{time_starttransfer}\n' \
  https://discuss.kde.org/<slow-path>
```

## Cutover

1. Lower the TTL on the `discuss.kde.org` record well before the switch.
2. Change the record to a CNAME pointing at the Fastly TLS hostname.
3. Watch the logs for 403s and origin errors. To roll back, point the record
   back at `cinclo.kde.org`.
