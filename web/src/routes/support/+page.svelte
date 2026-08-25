<svelte:head>
  <title>Support — Seedkeep</title>
  <meta name="description" content="Get help with Seedkeep." />
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
      Your iPhone or iPad model and iOS/iPadOS version (device Settings →
      General → About)
    </li>
    <li>The Seedkeep build number shown at the bottom of You → Settings</li>
    <li>What you were doing when it happened</li>
    <li>A screenshot or screen recording if visual</li>
  </ul>

  <h2>Common questions</h2>

  <h3>The AI extraction didn't recognize anything on my packet.</h3>
  <p>
    Free extraction works best with flat, well-lit photos of the entire front
    and back of the packet. Avoid glare, shadows, and fingers over the text. You
    can review and edit every extracted field before saving, or choose Add seed
    from the Library toolbar to enter a packet without scanning.
  </p>

  <h3>BYOK says that no API key is configured.</h3>
  <p>
    Open You → Settings → API keys and save a key for Anthropic or OpenAI, then
    choose BYOK and the matching provider under You → Settings → AI provider.
    The key stays in the device Keychain and is sent only to the provider you
    select.
  </p>

  <h3>Changes are not appearing on another device.</h3>
  <p>
    On each device, open You → Settings and choose “Sync now.” The Sync section
    shows whether the initial CloudKit upload completed, the last CloudKit sync
    time, and any error that needs a retry. Also choose “Check iCloud account”
    to confirm that iCloud is available on that device.
  </p>

  <h3>How do I share my seed library with my partner?</h3>
  <p>
    As the garden owner, open You → Settings → Share garden via iCloud and use
    Apple's sharing sheet to invite them. They accept Apple's invitation while
    signed in to iCloud with their own Apple ID. A participant can view and edit
    the shared library, garden, journal, and photos; You → Settings → Leave
    shared garden removes the participant's access without deleting the owner's
    garden.
  </p>

  <h3>Why does Seedkeep ask for a home ZIP?</h3>
  <p>
    You → Settings → Home location accepts a manually entered 5-digit US ZIP.
    Seedkeep uses it to look up a USDA zone and frost dates and to request a
    coarse local forecast for planting guidance and optional weather warnings.
    Seedkeep does not request Core Location or track your device's location.
  </p>

  <h3>How do I delete my account?</h3>
  <p>
    Open You → Delete account, review the role-specific steps, and confirm
    “Delete my account.” A participant leaves the shared garden without deleting
    it; a solo owner deletes the owned garden; an owner with accepted
    participants must hand the garden to an existing participant before deletion
    can finish. The flow checkpoints progress so you can retry after an
    interruption. See the <a href="/privacy">Privacy Policy</a> for retention details.
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
