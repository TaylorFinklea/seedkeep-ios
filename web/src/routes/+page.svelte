<svelte:head>
	<title>Seedkeep — Your household seed library</title>
	<meta
		name="description"
		content="Track every seed packet your household owns. Scan once with on-device AI, share with your gardening partner, and never lose track of what's viable, what's wishlist, or what came from last year's harvest."
	/>
	<meta property="og:title" content="Seedkeep" />
	<meta property="og:description" content="Your household seed library — on-device AI, offline-first, household-shared." />
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
		Seedkeep is the seed library your shoebox always wanted to be. Track every packet you own —
		what it is, when you bought it, where you stored it, what's still viable, what's a leftover
		from three Aprils ago. Built for households that share a garden, with last-write-wins sync so
		two people editing on two phones never lose work.
	</p>
</section>

<section class="features" aria-label="Features">
	<article class="feature">
		<h3>Scan once, remember forever.</h3>
		<p>
			Point your camera at a packet's barcode or take a front-and-back photo. Seedkeep extracts the
			common name, variety, company, and instructions on-device using Apple Intelligence — no
			servers, no accounts, no data shared.
		</p>
	</article>

	<article class="feature">
		<h3>Bring your own key.</h3>
		<p>
			Want higher-accuracy extraction? Paste your own OpenAI or Anthropic API key in Settings.
			The key lives in your device's Keychain and never reaches our servers.
		</p>
	</article>

	<article class="feature">
		<h3>Built for the seed aisle.</h3>
		<p>
			Add a packet at the garden center without signal — it syncs when you get home. Filter by
			active, wishlist, or self-harvested. Tap "Random pick" when you can't decide what to start
			this weekend.
		</p>
	</article>

	<article class="feature">
		<h3>Households, not accounts.</h3>
		<p>
			Sign in with Apple, share a household with one tap, and now two phones see the same seeds.
			Older packets get a viability warning so you know what to test before you waste a row.
		</p>
	</article>
</section>

<section class="closing">
	<p>
		v1 ships the seed library — what's in your shoebox, on the rack, in the freezer. Future
		updates add the garden plan, the journal, and the local-extension-service planting calendar.
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
