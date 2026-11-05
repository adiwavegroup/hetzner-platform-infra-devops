# Proposal: pin Traefik's encoded-character filtering on the public entryPoints

Status: **Proposed. Nothing is applied.** Not a change to `platform/traefik/values.yaml`, which stays a
verbatim copy until the ownership-transfer PR (see its header). This note is the input to a separate,
reviewable PR **after** adoption is stable and **after** the probe below has been run.

## Why

The `veracrm` tenant's licensesrv serves a public signup API on `adiwave.com`. Its application-level
admission gate (`OnboardingSoftLaunchWebFilter`) used to compare the raw request path, so
`/api/v1/onboarding/credentials;x=1` and `/api/v1/onboarding/%63redentials` reached the handler while the gate
saw a path that was not on its list. That is fixed in licensesrv (it now matches the decoded,
parameter-stripped path), so the application no longer depends on the edge. Defence in depth still wants
the edge to refuse ambiguous paths **before** any backend or middleware sees them: a path that two
components read differently is the root of this class of bypass.

## What the chart offers

Chart `traefik-41.0.2` (app v3.7.6), verified with
`helm show values traefik --repo https://traefik.github.io/charts --version 41.0.2`:

```yaml
ports:
  web:
    http:
      encodedCharacters:
        allowEncodedSlash:          # boolean | null   (null = Traefik's own default)
        allowEncodedBackSlash:
        allowEncodedNullCharacter:
        allowEncodedSemicolon:
        allowEncodedPercent:
        allowEncodedQuestionMark:
        allowEncodedHash:
  websecure:
    http:
      encodedCharacters: { ...same keys... }
```

Upstream reference: <https://doc.traefik.io/traefik/security/request-path/#encoded-character-filtering>.
The chart's default is `nil`, so today the deployed behaviour is whatever Traefik v3.7.6 does when unset.
**That default has not been verified here.**

## Step 1: probe before changing anything (read-only)

From a machine that can reach the origin, against a hostname safe to probe, record the status code and
whether the request reaches the backend (compare with the backend's access log, not just the status):

| Request path | Question |
| --- | --- |
| `/api/v1/onboarding/credentials;x=1` | does `;` reach the backend? |
| `/api/v1/onboarding/%63credentials` | is an encoded unreserved letter normalised before routing? |
| `/api/v1/onboarding%2fcredentials` | encoded slash |
| `/api/v1/onboarding%5ccredentials` | encoded backslash |
| `/api/v1/onboarding/credentials%00` | encoded NUL |
| `/api/v1/onboarding%3bcredentials` | encoded semicolon |
| `/api/v1/onboarding/credentials%25` | encoded percent |

Use an unauthenticated `POST` with an empty JSON body to a path whose expected answer is a fast 4xx. Do not
send credentials, and do not probe other tenants' hostnames.

## Step 2: the change, if the probe shows any of these reach a backend

Set the characters the platform does not need to `false` on **both** entryPoints:

```yaml
ports:
  web:
    http:
      encodedCharacters:
        allowEncodedSlash: false
        allowEncodedBackSlash: false
        allowEncodedNullCharacter: false
        allowEncodedSemicolon: false
        allowEncodedPercent: false
        allowEncodedQuestionMark: false
        allowEncodedHash: false
  websecure:
    http:
      encodedCharacters:   # same block
```

`allowEncodedPercent` is the one most likely to break something legitimate (a literal `%` in a URL is
sent as `%25`); decide it from the probe and from the tenants' real URLs, not by default.

## Blast radius and acceptance

Shared edge: this changes request handling for **every** tenant at once, which is why it is its own PR
(same rule as PR 5b: different blast radius, different rollback story).

Acceptance, per tenant, no exceptions (reuse the PR 5 list): veracrm hostnames, granite hostnames
(including media/s3/garage), `me.adiwave.group`, `registry.adiwave.com` (401), Stripe webhook reachable and
an unsigned payload rejected with 400, `http://` -> 301 with deep paths preserved, routing validator PASS in
all namespaces. Add: every probe row above is refused at the edge, and a real URL containing a legitimately
encoded character from each tenant still works.

Rollback: Helm rollback to the recorded revision.

## Ordering relative to PR 5b

Independent of `forwardedHeaders.trustedIPs` (PR 5b). Do not combine them: one is path handling, the other
is client-address attribution, and they must not share a revert.

## Probe results, 2026-10-17 (public edge, read-only)

Live Traefik arguments (`kubectl -n traefik get ds traefik`): image `traefik:v3.7.6`, **no**
`encodedCharacters` and **no** `forwardedHeaders` flags, so v3.7.6's built-in defaults apply. Requests were
unsigned `POST {}` to the Stripe webhook path on `adiwave.com` (expected: 400 from licensesrv), compared with
the same suffixes against the static site.

| Request path | Status | Reading |
| --- | --- | --- |
| `/api/v1/payment/webhooks/stripe` | 400 JSON | baseline: reaches licensesrv |
| `.../stripe;x=1` | 400, empty body | edge passes `;` through (nginx returned 200 for `/;x=1`), so licensesrv's own firewall refused it |
| `.../webhooks/%73tripe` | 400 JSON | an encoded unreserved letter is decoded before routing |
| `.../webhooks%2fstripe`, `%5c`, `%3b` | 404 `not_found` | not decoded; fell through to the static site, so no bypass |
| `.../stripe%00`, `.../stripe%25` | 400, empty body | edge passes them through (nginx: `/%25` is 200); licensesrv refused them |
| `.../stripe%3fx`, `%23x` | 401, empty body | treated as part of the segment; licensesrv's default-deny answered |
| `/webhooks/../webhooks/stripe`, `%2e%2e` | 400 JSON | dot segments are normalised to the canonical path |

Conclusions, and their limits:

- Traefik at its defaults does **not** refuse `;`, `%00` or `%25`; it forwards them. The backend refusing
  them is inferred from the empty-body 400 pattern; there is no access log on Traefik to confirm it, and the
  nginx static site has no such protection (`/%25` and `/;x=1` return the SPA).
- Nothing probed reached a *different* backend rule than the canonical path would, so no routing bypass was
  observed. Unreserved decoding and dot-segment cleaning are the only normalisation before routing, which is
  the case the licensesrv gate fix covers.
- Setting `allowEncodedSemicolon`, `allowEncodedNullCharacter` and `allowEncodedPercent` to `false` would move
  that refusal to the edge for **every** tenant, instead of leaving it to each backend's firewall. It is a
  hardening choice, not a fix for an observed exploit.
- Not probed: paths under `/api/v1/onboarding` (the new Gateway route is not deployed yet), other tenants'
  hostnames, and header-based forwarding.
