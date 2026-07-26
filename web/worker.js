export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		url.pathname = '/200';
		url.search = '';
		url.hash = '';

		return env.ASSETS.fetch(new Request(url, request));
	}
};
