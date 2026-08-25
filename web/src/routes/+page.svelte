<svelte:head>
  <title>Seedkeep — Plan, grow, and remember together</title>
  <meta
    name="description"
    content="Organize seed packets, plan garden beds, keep a journal, and share your garden through iCloud. Seedkeep works offline and syncs when a connection returns."
  />
  <meta property="og:title" content="Seedkeep" />
  <meta
    property="og:description"
    content="Your household seed library, garden plan, and journal — offline-ready and shared through iCloud."
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
    Free, MIT-licensed, self-hostable.
    <a href="https://github.com/TaylorFinklea/seedkeep-ios">iOS source</a> ·
    <a href="https://github.com/TaylorFinklea/seedkeep-server">Server source</a>
  </p>
</section>

<section class="intro">
  <p>
    Seedkeep turns your seed collection into a garden you can plan, plant, and
    remember. Organize every packet, lay out beds and planting events, keep a
    journal with photos and checklists, and get planting guidance for your home
    location. It is built for gardeners who share the work — and the record of
    what worked.
  </p>
</section>

<section class="features" aria-label="Features">
  <article class="feature">
    <h3>Scan once, remember forever.</h3>
    <p>
      Scan a barcode or photograph the front and back of a packet. The Free
      extractor uses Apple Vision and Foundation Models on your device. After
      extraction, Seedkeep submits the packet photos and structured result to
      its authenticated shared catalog so a future scan can find the same packet
      instantly.
    </p>
  </article>

  <article class="feature">
    <h3>Bring your own key.</h3>
    <p>
      Choose Anthropic or OpenAI and save your own API key in the device
      Keychain. The extraction request goes directly from your phone to that
      provider; Seedkeep never receives the key. The result then follows the
      same shared-catalog submission as Free extraction.
    </p>
  </article>

  <article class="feature">
    <h3>Built for the seed aisle.</h3>
    <p>
      Keep working when the connection disappears and sync when it returns.
      Track active, wishlist, saved, and archived packets; plan beds and
      planting events; and record what happened with journal entries,
      checklists, and photos.
    </p>
  </article>

  <article class="feature">
    <h3>Your garden, shared through iCloud.</h3>
    <p>
      Sign in with Apple and keep garden records and photos in your private
      iCloud database. An owner can invite another gardener with Apple's
      CloudKit sharing sheet, and participants can view and edit the same
      library, plans, and journal.
    </p>
  </article>
</section>

<section class="closing">
  <p>
    Five tabs keep the season together: Today for what needs attention, Library
    for every packet, Garden for beds and planting events, Journal for the
    record, and You for sharing and settings.
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
