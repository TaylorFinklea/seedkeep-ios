<script lang="ts">
	import '../app.css';
	let { children } = $props();
</script>

<a class="skip-link" href="#main">Skip to main content</a>

<div class="page">
	<header class="site-header container">
		<a class="brand" href="/" aria-label="Seedkeep — home">
			<img src="/logo-mark.png" alt="" class="brand-mark" width="36" height="36" />
			<span class="brand-text">Seedkeep</span>
		</a>
	</header>

	<main id="main" class="container">
		{@render children?.()}
	</main>

	<footer class="site-footer container">
		<p class="footer-row">
			<a href="/">Home</a>
			<span class="dot" aria-hidden="true">·</span>
			<a href="/privacy">Privacy</a>
			<span class="dot" aria-hidden="true">·</span>
			<a href="/support">Support</a>
			<span class="dot" aria-hidden="true">·</span>
			<a href="mailto:taylor.finklea@gmail.com">taylor.finklea@gmail.com</a>
		</p>
		<p class="footer-copy">© 2026 Taylor Finklea</p>
	</footer>
</div>

<style>
	.page {
		min-height: 100dvh;
		display: flex;
		flex-direction: column;
	}

	.site-header {
		padding-top: var(--space-lg);
	}

	.brand {
		display: inline-flex;
		align-items: center;
		gap: var(--space-sm);
		text-decoration: none;
		color: var(--text);
		border-bottom: none;
	}

	.brand-mark {
		display: block;
		width: 36px;
		height: 36px;
	}

	.brand-text {
		font-family: var(--font-serif);
		font-size: 1.35rem;
		letter-spacing: -0.01em;
	}

	main {
		flex: 1 0 auto;
		padding-top: var(--space-xl);
		padding-bottom: var(--space-xxxl);
	}

	.site-footer {
		border-top: 1px solid var(--divider);
		padding-top: var(--space-xl);
		padding-bottom: var(--space-xl);
		color: var(--text-muted);
		font-size: 0.92rem;
	}

	.footer-row {
		display: flex;
		flex-wrap: wrap;
		gap: var(--space-sm);
		align-items: center;
		margin-bottom: var(--space-sm);
	}

	.dot {
		color: var(--divider);
	}

	.footer-copy {
		margin: 0;
	}
</style>
