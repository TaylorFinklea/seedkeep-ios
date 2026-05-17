<svelte:head>
	<title>Support — Seedkeep</title>
	<meta name="description" content="Get help with Seedkeep." />
</svelte:head>

<a class="back-link" href="/">← Back to home</a>

<article class="support">
	<h1>Support</h1>

	<p>
		Email <a href="mailto:taylor.finklea@gmail.com?subject=Seedkeep%20support">taylor.finklea@gmail.com</a>
		with the question, bug, or feature request. Please include:
	</p>
	<ul>
		<li>Your iPhone model and iOS version (Settings → General → About)</li>
		<li>The Seedkeep version (Settings → About)</li>
		<li>What you were doing when it happened</li>
		<li>A screenshot or screen recording if visual</li>
	</ul>

	<h2>Common questions</h2>

	<h3>The AI extraction didn't recognize anything on my packet.</h3>
	<p>
		On-device extraction works best on flat, well-lit photos of the front and back of the packet.
		If the packet has heavy glare or wrinkles, manual entry is always available — tap "Enter
		manually" from the scan screen.
	</p>

	<h3>I'm signed in on two devices but only see seeds on one.</h3>
	<p>
		Pull-to-refresh on the Library tab triggers a sync. If that doesn't help, check Settings →
		Sync — pending writes appear there if a previous sync failed.
	</p>

	<h3>How do I share my seed library with my partner?</h3>
	<p>
		Settings → Invite → Create invite link. Share the code with them. They sign in on their phone,
		paste the code, and your inventory is shared. Household membership is symmetric — they can
		add and edit seeds the same as you.
	</p>

	<h3>How do I delete my account?</h3>
	<p>
		Email us from your account's email address with "Delete my account" in the subject. We
		process deletions within 30 days. See the
		<a href="/privacy">Privacy Policy</a> for details on what survives deletion (the anonymous
		catalog contributions remain).
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
