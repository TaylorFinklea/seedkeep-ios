<script lang="ts">
	import { page } from '$app/stores';
	
	// Transfer ID from the route parameter, never log or expose the token query param
	$: transferId = $page.params.id;
	$: appUrl = `seedkeep://garden-handoff/${transferId}${$page.url.search}`;
</script>

<svelte:head>
	<title>Open in Seedkeep</title>
	<meta name="robots" content="noindex, nofollow" />
</svelte:head>

<section class="handoff-fallback">
	<img src="/logo-mark.png" alt="" class="logo" width="120" height="120" />
	<h1>Open in Seedkeep</h1>
	<p class="instruction">
		This link opens in the Seedkeep app. If the app didn't open automatically, tap the button below.
	</p>
	<a href={appUrl} class="app-link">Open in Seedkeep</a>
	<p class="help">
		Don't have Seedkeep? <a href="/" class="home-link">Learn more</a>
	</p>
</section>

<style>
	.handoff-fallback {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		min-height: 100vh;
		padding: 2rem;
		text-align: center;
		font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
	}

	.logo {
		margin-bottom: 2rem;
		border-radius: 22%;
	}

	h1 {
		font-size: 1.75rem;
		font-weight: 600;
		margin: 0 0 1rem 0;
		color: #1a1a1a;
	}

	.instruction {
		font-size: 1rem;
		line-height: 1.5;
		color: #4a4a4a;
		max-width: 32rem;
		margin: 0 0 2rem 0;
	}

	.app-link {
		display: inline-block;
		padding: 0.875rem 2rem;
		background: #2c7a3e;
		color: white;
		text-decoration: none;
		border-radius: 0.5rem;
		font-weight: 500;
		transition: background 0.2s;
	}

	.app-link:hover {
		background: #245f31;
	}

	.help {
		margin-top: 2rem;
		font-size: 0.875rem;
		color: #6a6a6a;
	}

	.home-link {
		color: #2c7a3e;
		text-decoration: underline;
	}
</style>
