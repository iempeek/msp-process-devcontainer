# WireMock stubs for local dev (Twilio + ClickSend + Postmark + ChargeBee + Azure ARM/KV/SignalR + Teams Bot.Api)

Served by the `wiremock` sidecar (`.devcontainer/compose.yaml`) at
`http://wiremock:8080` (host: `http://localhost:8080`, admin UI at
`/__admin/`). Response templating is enabled globally.

Layout: one subfolder per vendor under `mappings/` (WireMock scans them
recursively), one mapping file per endpoint:

```
mappings/
  twilio/      clicksend/   postmark/      chargebee/
  azure-arm/   keyvault/    azure-signalr/ teamsbot/
  kb-widget/   (not a vendor - a static asset for the FRONTEND, see below)
  common/      (unmatched-vendor-fallback.json - JSON 404 for any
                unstubbed path in a known vendor namespace)
__files/       (response bodies served via "bodyFileName")
```

How the backend gets here (both via `settings.Local.json`):

- **Twilio** - the SDK hardcodes `api|messaging|pricing.twilio.com`, so
  `Twilio:ApiBaseUrl` makes `TwilioClientInitializer`
  (`Integrations/AlertManager.Integrations.Twilio/TwilioClientInitializer.cs`)
  rewrite every SDK request's scheme/host/port to this container. Paths are
  unique across the Twilio subdomains the code uses, so mappings match on
  path only.
- **Postmark** - `Postmark:ApiUrl` replaces the production
  `https://api.postmarkapp.com` base in `PostmarkUri`.
- **ClickSend** - `ClickSend:ApiUrl` replaces the production
  `https://rest.clicksend.com/v3` base in the ClickSend `RestClient`. Set it
  WITH the `/v3` suffix (`http://wiremock:8080/v3`) - the stubs match
  `/v3/...` paths to keep the vendor namespaces distinct.
- **ChargeBee** - `ChargeBee:ApiUrl` (full base INCLUDING `/api/v2`, i.e.
  `http://wiremock:8080/chargebee/api/v2`) is passed to the SDK's
  `ApiConfig.SetBaseUrl()`, its official override for the hardcoded
  `{site}.chargebee.com` host, and to the raw `HttpCallsClient`. The canned
  subscription carries the repo's REAL price ids (`Std_core_25000` plan +
  `Std_addOn_2500` addon, from `PricingPlans`) - `GenerateSubscriptionPlan`
  throws on ids it doesn't recognize, so don't change them casually.
  List stubs echo the `id[is]`/`customer_id[is]`/`subscription_id[is]`
  filters back; existence-check lists (`items`, `item_prices`,
  `price_variants`, `coupons`) always return a match, so "create if missing"
  flows treat everything as already existing and skip the create calls.
- **Azure ARM (white-label domain management)** -
  `Azure:ApiAccessData:ManagementUrl` / `LoginUrl` replace
  `https://management.azure.com` / `https://login.microsoftonline.com` in
  `AureUrlBuilder`, so the REAL `AzureAuthTokenService` runs unmodified.
- **Azure Key Vault** - the real `KeyVaultService` (Azure SDK) talks to
  wiremock's **HTTPS** port (`https://wiremock:8443`): Azure.Core refuses
  bearer auth over plain HTTP, and the self-signed cert is accepted via the
  `AzureAuthKeyVault:DangerousAcceptAnyServerCertificate` local setting
  (with `AuthorityHost` pointing the AAD token request here too). The stubs
  implement the vault's challenge flow: any `/secrets/...` request WITHOUT
  an Authorization header gets a 401 whose `WWW-Authenticate` tenant id must
  stay in sync with `AzureAuthKeyVault:ClientTenantId` in the overlay
  (`local-dev-tenant-id`). The store is STATELESS: the ARM token blob
  (`azure-api-access-token-data`) is the only seeded secret, writes are
  accepted but not persisted (a written value is NOT read back), and every
  other secret name 404s - seed more secrets as new mapping files if a
  local flow needs them.
- **Azure SignalR negotiate** - `Azure:NegotiateSignalRUrl` points at
  `http://wiremock:8080/signalr/negotiate`, so the real `SignalRService`
  (`Core/AlertManager.Services/SignalR/SignalRService.cs`, behind
  `POST /hub/negotiate` on AlertManager.Api) runs unmodified. The stub is a
  contract shim, NOT a fake hub: production negotiate answers
  `{url, accessToken}` pointing at Azure SignalR Service, whereas the local
  self-hosted `MspProcess.SignalR` host speaks the plain ASP.NET Core
  negotiate contract (`{connectionId, availableTransports, ...}`) and can't
  be pointed at directly. The stub just hands the browser
  `http://localhost:5229/hub` (a HOST-side URL - the frontend sidecar relays
  5229 into the devcontainer, see compose.yaml), where the real hub then
  does its own negotiate. `MspProcess.SignalR` must be running for
  websockets to work. The `accessToken` is decorative: `MainHub` has no
  `[Authorize]`. The other direction (backend -> hub `POST /api/notify`)
  never touches wiremock - `Azure:SignalRApiUrl` already points straight at
  `http://localhost:5229`.
- **Teams bot messaging (TeamsBotService + TechTeamsBotService)** - these
  never call Microsoft: they call OUR OWN `MspProcess.Bot.Api` (the host
  that isn't locally runnable - Entra + public endpoint). Zero code changes:
  `MicrosoftTeamsBot:BotUrl` (already a setting) points at
  `http://wiremock:8080/botapi/`, where stubs answer `botMessages/send` and
  all five `techBotMessages/*` routes (`sendAdaptiveCard` echoes the request
  `ConversationId` and mints a random activity id, which callers persist for
  later in-place card updates). NOTE: the services look up conversation
  references / channels in SQL first - without seeded
  `TeamsBotConversationReferences`/`TeamsBotChannels` rows they return
  "not found" before any HTTP call is made.

One stub is NOT a backend vendor mock - the **KB chat widget**
(`mappings/kb-widget/` + `__files/kb-chat-widget.js`). It is fetched by the
BROWSER, not by the backend, from `http://localhost:8080/kb-chat-widget.js`
(`REACT_APP_KB_WIDGET_URL` in `../frontend-settings/env.web`). The real widget
is a separate hosted product on `manage-dev.mspprocess.com` that does not exist
in this repo, so left unstubbed the local app's chat bubble opens a remote
iframe and shows the browser's network-error page whenever that host is
unreachable. The stand-in iframes the live chat widget we DO run locally
(:3004 -> LiveChat.Api :5033); see that file's header for the
`LOCAL_CHAT_WIDGET_CODE` / `KB_WIDGET_URL` knobs.

With this, the whole LocalMocks mechanism is gone (folder, DI overrides and
the `LocalMocks:Enabled` setting) - every former mock target runs its real
service against these stubs or the n8n sidecar.

Only the endpoints the codebase actually calls are stubbed; anything else
falls through to `common/unmatched-vendor-fallback.json`, which returns a
Twilio-style JSON 404 naming the missing mapping - add a new file in the
vendor's folder (and restart the sidecar, or POST it to `/__admin/mappings`)
when a new vendor call appears.

Gotchas encoded in the stubs:

- Twilio v2010 list responses need the paging envelope
  (`uri`, `next_page_uri`, ...) plus the records key
  (e.g. `incoming_phone_numbers`); v1 lists (messaging) need the `meta`
  envelope with `meta.key` naming the records property.
- `GET .../IncomingPhoneNumbers.json` echoes the `PhoneNumber` query filter
  back so "is this number in your Twilio account" checks always pass.
- `GET /v1/Services/{svc}/PhoneNumbers/{sid}` echoes `service_sid` from the
  path because callers compare it to the requested service.
- The hostname-binding stub always returns `sslState: SniEnabled`, so a
  domain assigned via `AssignDomainAsync` comes out SSL-enabled in one step
  and the separate generate/bind-certificate flows short-circuit with
  "Ssl already configured" (the certificates LIST is empty on purpose -
  its entries would need names derived from data not present in the
  request, so the bind-certificate lookup can't be faked faithfully).
- The web-app stub's `hostNames` includes bare TLD suffixes (".com",
  ".org", ...) because `RemoveDomainAsync` picks the binding to delete via
  `domain.Contains(hostName)` - any custom domain matches its TLD entry,
  which keeps domain removal working without knowing tenant domains.
