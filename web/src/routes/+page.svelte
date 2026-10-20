<svelte:head>
  <title>Seedkeep — Plan, grow, and remember together</title>
  <meta
    name="description"
    content="Organize seed packets, plan garden beds, keep a journal, and share your garden through iCloud. No Seedkeep account or server needed."
  />
  <meta property="og:title" content="Seedkeep" />
  <meta
    property="og:description"
    content="Your household seed library, garden plan, and journal — shared through iCloud."
  />
  <meta property="og:image" content="https://seedkeep.app/og-image.png" />
  <meta property="og:url" content="https://seedkeep.app/" />
  <meta property="og:type" content="website" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="Seedkeep" />
  <meta name="twitter:description" content="Your household seed library." />
  <meta name="twitter:image" content="https://seedkeep.app/og-image.png" />
</svelte:head>

<section class="hero">
  <img src="/logo-mark.png" alt="" class="hero-icon" width="200" height="200" />
  <h1>Seedkeep</h1>
  <p class="tagline">Your household seed library.</p>
  <span class="status">Coming soon to the App Store</span>
  <p class="source-note">
    Free and MIT-licensed.
    <a href="https://github.com/TaylorFinklea/seedkeep-ios">iOS source</a>
  </p>
</section>

<section class="intro">
  <p>
    Seedkeep turns your seed collection into a garden you can plan, plant, and
    remember. Organize every packet, lay out beds and planting events, keep a
    journal with photos and checklists, and see planting windows for your home
    ZIP code. It is built for gardeners who share the work — and the record of
    what worked.
  </p>
</section>

<section class="features" aria-label="Features">
  <article class="feature">
    <h3>Scan the packet, keep the details.</h3>
    <p>
      On iPhone and iPad, photograph the front and back of a packet. The Free
      option reads it on your device with Apple Vision and, when available,
      Apple's on-device foundation model. The result fills in a new seed, and
      both packet photos are saved to that seed in your iCloud garden.
    </p>
  </article>

  <article class="feature">
    <h3>Bring your own key.</h3>
    <p>
      Choose Anthropic or OpenAI and save your own API key in the device
      Keychain. Packet photos go directly from your device to that provider with
      your key. That provider's terms apply, and the app sends nothing to the
      developer. The result is saved the same way as a Free scan.
    </p>
  </article>

  <article class="feature">
    <h3>Plan the beds, then record the season.</h3>
    <p>
      Lay out garden beds and planting events, and keep a journal with photos
      and checklists. Planting windows are worked out on your device from each
      seed's growing information, your USDA hardiness zone, and the frost dates
      for your home ZIP code.
    </p>
  </article>

  <article class="feature">
    <h3>Your garden, shared through iCloud.</h3>
    <p>
      There is no Seedkeep account to create. Your garden lives in your private
      iCloud database. An owner can invite another gardener from You → Settings
      with “Share garden via iCloud,” and participants can view and edit the
      same garden. Shared data stays in the owner's iCloud, and a participant
      can leave.
    </p>
  </article>
</section>

<section class="closing">
  <p>
    On iPhone, five tabs keep the season together: Today for what needs
    attention, Library for every packet, Garden for beds and planting events,
    Journal for the record, and You for sharing and settings. On a wide iPad and
    on Mac, a sidebar puts your seeds in a spreadsheet-style table.
  </p>
</section>

<style>
  .hero {
    text-align: center;
    padding: var(--space-xl) 0 var(--space-lg);
  }

  .hero-icon {
    display: block;
    margin: 0 auto var(--space-md);
    width: 200px;
    height: 200px;
    border-radius: 44px;
  }

  .tagline {
    font-size: 1.25rem;
    color: var(--text-muted);
    margin: 0 0 var(--space-lg);
  }

  .status {
    display: inline-block;
    font-size: 0.85rem;
    padding: 0.35rem 0.9rem;
    background: var(--brand-cream-dim);
    color: var(--text-muted);
    border-radius: 999px;
    letter-spacing: 0.02em;
  }

  .source-note {
    margin-top: var(--space-md);
    font-size: 0.9rem;
    color: var(--text-muted);
  }

  .intro p,
  .closing p {
    font-size: 1.1rem;
    line-height: 1.6;
  }

  .features {
    display: grid;
    gap: var(--space-xl);
    margin-top: var(--space-xl);
  }

  .feature h3 {
    font-family: var(--font-serif);
    margin-bottom: var(--space-xs);
  }

  .feature p {
    margin: 0;
    color: var(--text-muted);
    line-height: 1.6;
  }

  .closing {
    margin-top: var(--space-xl);
    padding-top: var(--space-xl);
    border-top: 1px solid var(--divider);
    color: var(--text-muted);
  }
</style>
