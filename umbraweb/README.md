# Umbra website

Marketing site for Umbra and Penumbra. It is a [vinext](https://vinext.dev) app (Next.js App Router on Vite) deployed to Cloudflare Workers as `umbraweb`.

The page is prerendered at build time and served from Workers Static Assets. There is no shared data cache and no image optimization.

```bash
cd umbraweb
npm run dev      # local dev server
npm run build    # production build
npm run start    # preview the built Worker
npm run deploy   # build and deploy (needs a Cloudflare login)
```

Deploy from a machine with `cf auth login`, or set `CLOUDFLARE_ACCOUNT_ID`. CI (`.github/workflows/umbraweb.yml`) uses `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. The Worker publishes `umbraeditor.com` and `www.umbraeditor.com`; `www` redirects to `https://umbraeditor.com`. The zone has to be on the same Cloudflare account.

GitHub Pages still hosts the Sparkle update feed at `website/appcast.xml`. Shipped Umbra builds request `https://alex-cova.github.io/Penumbra/appcast.xml`, so that path stays on Pages.
