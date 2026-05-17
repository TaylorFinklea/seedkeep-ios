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
		<strong>Effective:</strong> May 16, 2026 ·
		<strong>App:</strong> Seedkeep (iOS) ·
		<strong>Bundle ID:</strong> <code>app.seedkeep.ios</code> ·
		<strong>Developer:</strong> Taylor Finklea
	</p>

	<h2>The short version</h2>
	<p>
		Seedkeep stores the seed-packet inventory you enter, syncs it across the devices in your
		household, and contributes scanned packets to a shared catalog so the next person who scans
		the same packet doesn't have to re-extract it. That's it — no analytics, no advertising IDs,
		no third-party SDKs, no data sold or shared with anyone else.
	</p>

	<h2>What we collect</h2>
	<ul>
		<li>
			<strong>Apple Sign-in identifier (subject claim)</strong> — lets you sign in across devices.
			We never receive your email or name from Apple unless you choose to share them on first
			sign-in. Stored on our server.
		</li>
		<li>
			<strong>Seed inventory you enter</strong> — names, varieties, packet counts, locations,
			tags, notes, year packed, and state (active / wishlist / saved / archived). Stored on our
			server so it syncs to your other devices and household members.
		</li>
		<li>
			<strong>Seed-packet photos</strong> — when you scan a packet, the front-and-back photos are
			uploaded to our object storage so they can serve other households scanning the same packet.
			You can disable this in Settings → Privacy if you'd rather keep your packets private.
		</li>
		<li>
			<strong>Server logs</strong> — like any web service, our server records IP addresses and
			request timestamps for the standard ~30-day window. We use these only to diagnose problems
			and detect abuse; they're not used for tracking or analytics.
		</li>
	</ul>

	<h2>What we don't collect</h2>
	<ul>
		<li>We don't use analytics, telemetry, crash reporters, advertising IDs, or fingerprinting.</li>
		<li>We don't embed third-party SDKs.</li>
		<li>We don't read your contacts, calendars, location, microphone, or camera roll — only the
			photos you explicitly take inside the app for seed packets.</li>
		<li>We don't sell, rent, or trade any data with anyone.</li>
		<li>We don't use your data to train AI models.</li>
	</ul>

	<h2>AI extraction</h2>
	<p>
		Seedkeep offers three ways to extract packet info from photos:
	</p>
	<ul>
		<li>
			<strong>Free (on-device)</strong> — Apple Intelligence runs Vision OCR and Foundation Models
			on your device. Nothing leaves your phone for extraction. The structured result is then
			synced like any other seed entry.
		</li>
		<li>
			<strong>BYOK (your own key)</strong> — you provide an Anthropic or OpenAI API key. The
			extraction call goes directly from your phone to that provider. Your key lives in your
			device's Keychain and is never sent to us. Anthropic and OpenAI's privacy practices govern
			what they do with the request.
		</li>
		<li>
			<strong>Hosted</strong> — (paid tier, not yet available in v1) we run extraction on our
			server using our own API key, billed via Apple's In-App Purchase. When this launches we'll
			update this policy to disclose what data the call carries.
		</li>
	</ul>

	<h2>Shared catalog</h2>
	<p>
		When you scan a packet, Seedkeep checks whether the same packet has been scanned before. If
		yes, you get an instant match — the catalog entry already exists. If no, your scan creates
		the catalog entry: the structured packet info (common name, variety, company, instructions),
		your extraction confidence score, and the packet photos are stored in our catalog so the next
		household to scan the same packet doesn't have to re-extract.
	</p>
	<p>
		The catalog contribution is anonymous — it doesn't reveal who scanned the packet. Disable
		catalog contributions in Settings → Privacy if you'd rather your packets stay private to your
		household.
	</p>

	<h2>Household sharing</h2>
	<p>
		Inviting someone to your household via a one-time code shares your full inventory with them.
		Removing them from the household stops their access. Phase 1 doesn't support read-only roles —
		household members have equal write access. If you need finer permissions, sit tight until v1.1.
	</p>

	<h2>Children</h2>
	<p>
		Seedkeep is rated 4+ and contains no objectionable content. We do not knowingly collect data
		from children under 13. If you're a parent and discover your child has created a Seedkeep
		account, email <a href="mailto:taylor.finklea@gmail.com">taylor.finklea@gmail.com</a> and we
		will delete the account and any associated inventory.
	</p>

	<h2>Data retention &amp; deletion</h2>
	<p>
		Your inventory is stored as long as your account exists. You can delete individual seeds from
		within the app (soft-delete, hidden but recoverable for 30 days). To delete your entire
		account and all associated data, email
		<a href="mailto:taylor.finklea@gmail.com">taylor.finklea@gmail.com</a> from the email
		address tied to your Apple ID. Account deletion is permanent and processed within 30 days.
	</p>
	<p>
		Catalog contributions (anonymous packet entries) survive account deletion, because they were
		shared with the catalog at scan time and are no longer associated with you.
	</p>

	<h2>Where data lives</h2>
	<p>
		The Seedkeep server runs on Fly.io in the United States (region <code>iad</code>). The
		Postgres database is hosted on Fly.io. Seed-packet photos are stored in Cloudflare R2. All
		data in transit is TLS-encrypted; data at rest is encrypted by the storage providers.
	</p>

	<h2>Changes</h2>
	<p>
		If we ever change what we collect or how we use it, we'll update this page and bump the
		"Effective" date at the top. Material changes will also surface in the app via a one-time
		notice.
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
