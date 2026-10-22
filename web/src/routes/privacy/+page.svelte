<svelte:head>
  <title>Privacy Policy — Seedkeep</title>
  <meta
    name="description"
    content="The current Seedkeep app has no server and no account. Your garden stays in your iCloud, the app sends nothing to the developer, and there are no analytics, trackers, or ads."
  />
</svelte:head>

<a class="back-link" href="/">← Back to home</a>

<article class="policy">
  <h1>Privacy Policy</h1>

  <p class="meta">
    <strong>Effective:</strong> October 22, 2026 ·
    <strong>App:</strong> Seedkeep (iPhone, iPad, and Mac) ·
    <strong>Bundle ID:</strong> <code>app.seedkeep.ios</code> ·
    <strong>Developer:</strong> Taylor Finklea
  </p>

  <h2>The short version</h2>
  <p>
    The current Seedkeep app has no Seedkeep server and no Seedkeep account. The
    app uses your iCloud account: your garden records and photos are stored in
    your private iCloud database (CloudKit) and on your devices, and the developer
    cannot access them. Seedkeep has no advertising, tracking, analytics, or
    telemetry, and does not sell your data. Packet scans are read on your device
    with the Free option. If you choose BYOK with your own API key, the packet
    photos go directly from your device to the AI provider you chose, under that
    provider's terms, and Seedkeep never receives them. Apple WeatherKit receives
    the coordinates of your home location to forecast the weather. The sections
    below explain each part.
  </p>

  <h2>What we collect</h2>
  <ul>
    <li>
      <strong>iCloud record identifier</strong> — the app reads the iCloud user record
      identifier Apple provides, an opaque ID specific to Seedkeep's iCloud container,
      so it can recognize which garden is yours. The identifier is kept on your device.
    </li>
    <li>
      <strong>Garden content</strong> — seed inventory, storage locations, tags, notes,
      garden beds, planting events, journal entries, checklists, and seed or journal
      photos. This content is stored in your private iCloud database (CloudKit) and
      on your devices. The developer cannot access it.
    </li>
    <li>
      <strong>Packet photos and scan results</strong> — the front-and-back packet
      photos and the fields read from them. The result fills in a new seed, and both
      photos are saved as that seed's photos in your iCloud garden.
    </li>
    <li>
      <strong>Home location</strong> — the 5-digit US ZIP code you may enter under
      Settings → Home location. The app looks it up in a table bundled in the app,
      which gives the USDA plant hardiness zone, approximate coordinates of the ZIP
      area, and estimated frost dates. The lookup makes no network request, and the
      ZIP is stored only on that device. The coordinates are sent to Apple WeatherKit;
      see “Location, WeatherKit, and notifications” below.
    </li>
  </ul>

  <h2>What we don't collect</h2>
  <ul>
    <li>
      Seedkeep does not use analytics, telemetry, crash-reporting SDKs,
      advertising IDs, or fingerprinting, and does not track you.
    </li>
    <li>
      The app has no advertising, in-app purchases, subscriptions, or hosted AI.
    </li>
    <li>
      Seedkeep does not request your device's location (no Core Location). The
      only location it uses is the ZIP code you enter.
    </li>
    <li>
      Seedkeep accesses the camera or photo library only when you choose to take
      or pick a photo.
    </li>
    <li>
      Seedkeep does not sell, rent, or trade your data, and does not use it to
      train AI models.
    </li>
  </ul>

  <h2>Packet scanning</h2>
  <p>
    On iPhone and iPad, you can scan a packet with the camera. The app offers
    two options:
  </p>
  <ul>
    <li>
      <strong>Free (on-device)</strong> — Apple Vision reads the packet's text on
      your device and, when it is available, Apple's on-device foundation model sorts
      it into fields. Without the model, some fields may stay empty. The app sends
      nothing to the developer.
    </li>
    <li>
      <strong>BYOK (bring your own key)</strong> — you choose Anthropic or
      OpenAI and save your own API key in the device Keychain. Your packet photos are
      sent directly from your device to that provider's API, using your key, under
      that provider's terms. Seedkeep never receives the photos or your key, and the
      developer cannot see them. The provider may retain the photos under its own
      policy and your account settings. Deleting content in Seedkeep does not delete
      anything the provider holds. See the
      <a href="https://www.anthropic.com/legal/privacy">Anthropic</a> and
      <a href="https://openai.com/policies/privacy-policy">OpenAI</a> privacy policies.
      To stop BYOK uploads, choose Free under Settings → AI provider and clear your
      keys under Settings → API keys.
    </li>
  </ul>
  <p>
    With either option, the result fills in a new seed and both packet photos
    are saved as that seed's photos in your iCloud garden.
  </p>

  <h2>Earlier test versions</h2>
  <p>
    Test versions released before October 2026 used a Seedkeep server for Sign
    in with Apple accounts, a shared seed catalog of packet photos and extracted
    fields contributed by users, home ZIP lookup, and account deletion. The current
    app does not use that server. The old server and its accounts are being
    retired. If you had an account on it and want its data deleted, or have a
    question about it, email
    <a href="mailto:support@finklea.dev">support@finklea.dev</a>.
  </p>

  <h2>Household sharing</h2>
  <p>
    Garden sharing uses Apple's iCloud sharing. An owner can choose “Share
    garden via iCloud” in Settings and send Apple's invitation. Accepted
    participants can view and edit the shared garden. A participant can leave
    with “Leave shared garden” in Settings. The owner manages the share through
    Apple's sharing controls. Shared garden data stays in iCloud under the owner's
    account.
  </p>

  <h2>Location, WeatherKit, and notifications</h2>
  <p>
    Planting windows are computed on your device from each seed's growing
    information, the hardiness zone, and the frost dates for your home ZIP code.
  </p>
  <p>
    <strong>WeatherKit.</strong> To fetch forecasts for planting windows and
    opted-in weather warnings, the app sends the coordinates of your home location
    to Apple WeatherKit. Those coordinates are derived from the ZIP code you enter.
    The request carries the coordinates only, not the ZIP code. Apple's WeatherKit
    terms and privacy policy apply to that service. Seedkeep does not request your
    device's location.
  </p>
  <p>
    Notifications, such as frost, heat, and watering reminders, are scheduled
    locally on your device. The app does not use remote push notifications.
  </p>

  <h2>Children</h2>
  <p>
    Seedkeep is rated 4+. The app does not send data to the developer, from
    anyone, including children under 13. If you have a question about children's
    privacy, email
    <a href="mailto:support@finklea.dev">support@finklea.dev</a>.
  </p>

  <h2>Data retention &amp; deletion</h2>
  <p>
    Seedkeep does not keep your garden on a Seedkeep server, so you delete data
    in the app or in iCloud:
  </p>
  <ul>
    <li>
      <strong>Individual items</strong> — deleting a seed, bed, or journal entry in
      the app hides it on all your synced devices. The record stays in your iCloud
      garden, marked as deleted, and photos of deleted seeds are not yet removed from
      iCloud.
    </li>
    <li>
      <strong>The app</strong> — on iPhone and iPad, deleting Seedkeep removes the
      garden copy stored on that device. On Mac, deleting the app does not remove
      that copy. Quit Seedkeep, move it to the Trash, and then delete the folder
      ~/Library/Containers/app.seedkeep.ios in your home folder, which holds the
      Mac app's local data. Deleting the app does not delete your iCloud garden.
      BYOK API keys saved in the Keychain can remain after the app is removed; clear
      them first under Settings → API keys.
    </li>
    <li>
      <strong>Seedkeep data in your iCloud account</strong> — first delete the
      Seedkeep app from all your devices, including this one: a device that still has
      the app and unsynced changes can upload them again. On Mac, delete the folder
      described above as well. Then delete the data in your
      Apple Account's iCloud storage settings:
      <ul>
        <li>
          On iPhone or iPad, open the Settings app, tap [your name], tap iCloud, and
          open your iCloud storage (labeled Manage Account Storage or Manage Storage,
          depending on your iOS version). Choose Seedkeep and tap Delete Data.
        </li>
        <li>
          On Mac, open System Settings, click [your name], click iCloud, and open your
          iCloud storage (labeled Manage). Choose Seedkeep and delete its data.
        </li>
        <li>
          Apple changes these labels between versions. If they differ on your device,
          look for Seedkeep in your Apple Account's iCloud storage settings.
        </li>
      </ul>
      This does not delete a garden that someone else owns and shared with you.
    </li>
  </ul>
  <!-- Confirm the release bundle ID in the built Mac app's Info.plist before publishing: the Mac folder named under "The app" depends on it. -->
  <!-- N2-E: once the in-app "Delete data" path ships and is tested on iPhone, iPad, and Mac, replace the iCloud steps above with it. Do not publish these steps unverified on both platforms. -->
  <p>
    If you email support, the developer receives what you send, such as your
    email address, device details, and screenshots, and uses it only to answer
    you. Ask at any time to have it deleted.
  </p>
  <p>For data from earlier test versions, see “Earlier test versions” above.</p>

  <h2>Where data lives</h2>
  <p>
    Garden records and photos live in your private iCloud database (CloudKit)
    and on your devices. A shared garden stays in iCloud under the owner's
    account. Apple provides iCloud and WeatherKit. Anthropic or OpenAI receive
    packet photos directly from your device only when you choose BYOK, under their
    own terms and privacy policies. Seedkeep never receives them.
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
    <a href="mailto:support@finklea.dev">support@finklea.dev</a>
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
