<svelte:head>
  <title>Support — Seedkeep</title>
  <meta
    name="description"
    content="Get help with Seedkeep: iCloud sync, garden sharing, packet scanning, home location, and deleting your data."
  />
</svelte:head>

<a class="back-link" href="/">← Back to home</a>

<article class="support">
  <h1>Support</h1>

  <p>
    Email <a href="mailto:taylor.finklea@gmail.com?subject=Seedkeep%20support"
      >taylor.finklea@gmail.com</a
    >
    with the question, bug, or feature request. Please include:
  </p>
  <ul>
    <li>
      Your device model and OS version (on iPhone or iPad: Settings → General →
      About)
    </li>
    <li>The Seedkeep build number shown at the bottom of You → Settings</li>
    <li>What you were doing when it happened</li>
    <li>A screenshot or screen recording if visual</li>
  </ul>

  <h2>Common questions</h2>

  <h3>Packet scanning didn't recognize anything on my packet.</h3>
  <p>
    Scanning works best with flat, well-lit photos of the entire front and back
    of the packet. Avoid glare, shadows, and fingers over the text. Before
    saving, you can review the extracted growing information and edit the seed's
    name, variety, company, and notes, or choose Add seed in the Library toolbar
    to enter a packet by hand. The Free option uses Apple's on-device foundation
    model when your device has it; without it, some fields may stay empty.
  </p>

  <h3>BYOK says that no API key is configured.</h3>
  <p>
    Open You → Settings → API keys and save a key for Anthropic or OpenAI, then
    choose BYOK under You → Settings → AI provider. If both keys are saved,
    Seedkeep uses Anthropic; clear the Anthropic key to use OpenAI. The key
    stays in the device Keychain and is sent only to that provider.
  </p>

  <h3>Changes are not appearing on another device.</h3>
  <p>
    Garden data syncs through your iCloud account, so each device must be signed
    in to iCloud. On each device, open You → Settings and choose “Sync now.”
    Also choose “Check iCloud account” to confirm that iCloud is available on
    that device.
  </p>

  <h3>How do I share my garden with my partner?</h3>
  <p>
    As the garden owner, open You → Settings → Share garden via iCloud and use
    Apple's sharing sheet to invite them. They accept Apple's invitation while
    signed in to iCloud with their own Apple ID. A participant can view and edit
    the shared garden. A participant can leave with You → Settings → Leave
    shared garden. The owner manages the share through Apple's sharing controls,
    and shared data stays in iCloud under the owner's account.
  </p>

  <h3>Why does Seedkeep ask for a home ZIP?</h3>
  <p>
    You can enter a 5-digit US ZIP code under You → Settings → Home location.
    Seedkeep looks it up in a table bundled in the app to find your USDA
    hardiness zone, approximate coordinates, and estimated frost dates. The
    lookup makes no network request, and the ZIP is stored only on that device.
    Planting windows use the zone and frost dates, and the coordinates are used
    to request a local weather forecast from Apple WeatherKit. Seedkeep does not
    request your device's location.
  </p>

  <h3>How do I delete my data?</h3>
  <p>
    Seedkeep has no account to delete. Deleting a seed, bed, or journal entry in
    the app hides it on all your synced devices; the record stays in your iCloud
    garden, marked as deleted. Deleting Seedkeep from a device removes the copy
    on that device but not your iCloud garden, and BYOK keys can remain in the
    Keychain, so clear them first under You → Settings → API keys. To delete the
    data Seedkeep keeps in your iCloud account, first delete the Seedkeep app
    from all your devices, including this one, then open the device's Settings
    app. On iPhone or iPad, go to [your name] → iCloud → Manage Storage (or
    Storage), choose Seedkeep, and tap Delete Data. On Mac, go to System
    Settings → [your name] → iCloud → Manage, and choose Seedkeep. See the <a
      href="/privacy">Privacy Policy</a
    > for details.
  </p>
</article>

<style>
  .back-link {
    display: inline-block;
    margin-bottom: var(--space-lg);
    font-size: 0.9rem;
    border-bottom: none;
  }

  .support h2 {
    margin-top: var(--space-xl);
  }

  .support ul {
    padding-left: 1.2rem;
  }

  .support li {
    margin-bottom: var(--space-sm);
  }
</style>
