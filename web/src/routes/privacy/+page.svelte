<svelte:head>
  <title>Privacy Policy — Seedkeep</title>
  <meta
    name="description"
    content="Seedkeep stores only what you enter. Catalog photos are shared so other households scanning the same packet get an instant match. No analytics, no trackers, no third-party SDKs."
  />
</svelte:head>

<a class="back-link" href="/">← Back to home</a>

<article class="policy">
  <h1>Privacy Policy</h1>

  <p class="meta">
    <strong>Effective:</strong> August 22, 2026 ·
    <strong>App:</strong> Seedkeep (iOS) ·
    <strong>Bundle ID:</strong> <code>app.seedkeep.ios</code> ·
    <strong>Developer:</strong> Taylor Finklea
  </p>

  <h2>The short version</h2>
  <p>
    Seedkeep stores your garden records and photos in your iCloud garden. Its
    service stores the account information needed for Sign in with Apple, your
    manually entered home ZIP and derived coarse location, and packet scans and
    corrections contributed to the shared seed catalog. Seedkeep has no
    advertising, tracking, analytics, or telemetry, and does not sell your data.
    The sections below explain the services that receive data to provide these
    features.
  </p>

  <h2>What we collect</h2>
  <ul>
    <li>
      <strong>Account information</strong> — your Sign in with Apple identifier, Seedkeep
      account and household identifiers, and the name or email Apple provides if you
      choose to share them. The Seedkeep service uses this information to authenticate
      you and operate your account.
    </li>
    <li>
      <strong>Garden content</strong> — seed inventory, storage locations, tags, notes,
      garden beds, planting events, journal entries, checklists, and seed or journal
      photos. This content is stored in your private CloudKit garden and, when you
      share a garden, the associated CloudKit share.
    </li>
    <li>
      <strong>Packet scans and catalog contributions</strong> — the front-and-back
      packet photos, barcode when available, extracted packet fields, model identifier,
      and confidence values. The app submits these through your authenticated account
      to Seedkeep's shared catalog service.
    </li>
    <li>
      <strong>Catalog corrections</strong> — suggested field changes, explanatory
      notes, and their review status. These are stored with your account so you can
      see the outcome in the app.
    </li>
    <li>
      <strong>Coarse home location</strong> — the 5-digit US ZIP you enter in You
      → Settings → Home location, plus the coarse coordinates, USDA zone, and frost
      dates derived from it. Seedkeep uses these for planting guidance and WeatherKit
      forecasts.
    </li>
    <li>
      <strong>Service-operation data</strong> — hosting providers and service logs
      may process an IP address, request time, endpoint, and error details to deliver
      requests, secure the service, prevent abuse, and diagnose failures. Seedkeep
      does not use this information for advertising or cross-app tracking.
    </li>
  </ul>

  <h2>What we don't collect</h2>
  <ul>
    <li>
      Seedkeep does not use analytics, telemetry, crash-reporting SDKs,
      advertising IDs, or fingerprinting.
    </li>
    <li>
      The current app has no advertising, subscription, in-app purchase, or
      hosted AI tier.
    </li>
    <li>
      Seedkeep does not request Core Location and does not collect precise,
      continuous, or background location. Location comes only from the ZIP you
      enter.
    </li>
    <li>
      Seedkeep does not read your contacts, calendars, or microphone. It
      accesses the camera or photos only when you choose to capture or select an
      image for a Seedkeep feature.
    </li>
    <li>
      Seedkeep does not sell, rent, or trade your data, and does not use it to
      train Seedkeep-owned AI models.
    </li>
  </ul>

  <h2>AI extraction</h2>
  <p>
    The current app offers two ways to extract packet information from photos:
  </p>
  <ul>
    <li>
      <strong>Free (on-device)</strong> — Apple Vision and Foundation Models perform
      the extraction on your device. Afterward, the app submits the front-and-back
      packet photos and structured result to Seedkeep's authenticated shared-catalog
      service.
    </li>
    <li>
      <strong>BYOK (bring your own key)</strong> — you choose Anthropic or OpenAI
      and save your API key in the device Keychain. Seedkeep sends the packet photos
      directly from your device to that provider for extraction; the key never reaches
      Seedkeep's service. The provider's terms and privacy policy govern that request.
      The app then submits the same packet photos and structured result to Seedkeep's
      shared catalog.
    </li>
  </ul>

  <h2>Shared catalog</h2>
  <p>
    When you scan a barcode, Seedkeep first checks whether the shared catalog
    already knows the packet. A new extraction contributes the packet photos,
    structured fields, and confidence data so future scans can match it. Catalog
    submissions are authenticated and are conservatively treated as linked to
    your account for privacy disclosure, even though the catalog shown to other
    users does not display the contributor's identity.
  </p>
  <p>
    A shared catalog entry may remain after account deletion because it has
    become reusable catalog data rather than part of a household garden. Contact
    us if you have a concern about a specific catalog contribution.
  </p>

  <h2>Household sharing</h2>
  <p>
    Garden sharing uses Apple's CloudKit sharing system. From You → Settings, an
    owner can choose “Share garden via iCloud” and send Apple's invitation. An
    accepted participant can view and edit the shared seed library, garden plan,
    journal, and photos. A participant can choose “Leave shared garden”; the
    owner can manage the share through Apple's sharing controller. CloudKit
    sharing does not send the garden's record contents to the Seedkeep service.
  </p>

  <h2>Location, WeatherKit, and notifications</h2>
  <p>
    When you save a home ZIP, the Seedkeep service resolves it to coarse
    coordinates, a USDA zone, and frost dates. The app caches those values and
    uses the coordinates to request a local forecast from Apple WeatherKit.
    Seedkeep does not request your device's location. Notifications are
    scheduled locally on your device for features you enable; the current app
    does not use remote push notifications.
  </p>

  <h2>Children</h2>
  <p>
    Seedkeep is rated 4+ and contains no objectionable content. We do not
    knowingly collect data from children under 13. If you're a parent and
    discover your child has created a Seedkeep account, email <a
      href="mailto:taylor.finklea@gmail.com">taylor.finklea@gmail.com</a
    >.
  </p>

  <h2>Data retention &amp; deletion</h2>
  <p>
    Garden content remains in its CloudKit garden until you delete the content,
    leave the share, or complete account deletion. To delete your account in the
    app, choose You → Delete account and confirm “Delete my account.” Opening
    the flow alone deletes nothing. The resumable flow handles your CloudKit
    role before deleting the Seedkeep account last:
  </p>
  <ul>
    <li>
      <strong>Participant</strong> — leaves the accepted share without deleting the
      owner's or other participants' garden.
    </li>
    <li>
      <strong>Solo owner</strong> — deletes the owned CloudKit garden and then the
      Seedkeep account.
    </li>
    <li>
      <strong>Owner with accepted participants</strong> — must hand the garden to
      an existing participant and verify the copy before the original garden and departing
      account can be deleted.
    </li>
  </ul>
  <p>
    Shared catalog entries may remain as described above. Minimal deletion
    receipts and operational records may also be retained when needed to verify
    completion, prevent replay or abuse, comply with law, or resolve a support
    request; they cannot restore a deleted garden or account.
  </p>

  <h2>Where data lives</h2>
  <p>
    Garden records and garden photos live in Apple's CloudKit under your private
    database or an accepted share. The official Seedkeep service runs on Fly.io
    in the United States; its Postgres database stores account and catalog
    records, and Cloudflare R2 stores shared packet images. Network requests use
    TLS. Apple, Fly.io, Cloudflare, and—only when you choose BYOK—Anthropic or
    OpenAI process data as service providers under their own terms and privacy
    policies.
  </p>
  <p>
    Seedkeep is open-source and can connect to a separately operated Seedkeep
    server. If you choose a server other than the official service, that
    server's operator controls its server-side data practices; this policy
    covers the official Seedkeep service.
  </p>

  <h2>Changes</h2>
  <p>
    If what Seedkeep collects or how it uses data changes, this page and the
    “Effective” date will be updated. Additional notice will be provided when
    required by law.
  </p>

  <h2>Contact</h2>
  <p>
    Questions, requests, or anything else:
    <a href="mailto:taylor.finklea@gmail.com">taylor.finklea@gmail.com</a>
  </p>
</article>

<style>
  .back-link {
    display: inline-block;
    margin-bottom: var(--space-lg);
    font-size: 0.9rem;
    border-bottom: none;
  }

  .policy h1 {
    font-size: 2.2rem;
  }

  .meta {
    color: var(--text-muted);
    font-size: 0.9rem;
    line-height: 1.7;
    margin-bottom: var(--space-xl);
  }

  .policy h2 {
    margin-top: var(--space-xl);
  }

  .policy ul {
    padding-left: 1.2rem;
  }

  .policy li {
    margin-bottom: var(--space-sm);
  }
</style>
