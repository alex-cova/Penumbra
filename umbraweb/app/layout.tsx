import type { Metadata, Viewport } from "next";
import "./globals.css";
import { KitBoot } from "./kit-boot";

const title = "Umbra: code editor for macOS developers";
const description =
  "Umbra is an AppKit editor on the Penumbra engine, with a Sublime keymap, Java intelligence and a coding agent in one window. Requires macOS 26.";

export const metadata: Metadata = {
  metadataBase: new URL("https://umbraeditor.com"),
  title,
  description,
  alternates: { canonical: "/" },
  icons: { icon: "/umbra.png", apple: "/umbra.png" },
  openGraph: {
    type: "website",
    url: "https://umbraeditor.com",
    title,
    description,
    images: ["/share.jpg"],
  },
  twitter: { card: "summary_large_image", title, description, images: ["/share.jpg"] },
};

export const viewport: Viewport = {
  themeColor: "#0a0a0d",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className="m-enter m-enter-done mo-js"
      data-type="software"
      data-radius="sharp"
      data-ground="sky"
      data-buttons="arrow"
      data-motion
      suppressHydrationWarning
    >
      <head>
        <meta name="site-kind" content="software" />
        <meta name="page-type" content="software" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          href="https://fonts.googleapis.com/css2?family=Sora:wght@400..700&family=Figtree:wght@400..600&family=Martian+Mono:wght@400..500&display=swap"
          rel="stylesheet"
        />
        <link rel="stylesheet" href="/assets/system.css" />
        <link rel="stylesheet" href="/assets/ui/cards.css" />
        <link rel="stylesheet" href="/assets/motion/motion.css" />
        <link rel="stylesheet" href="/assets/backgrounds/backgrounds.css" />
        <link rel="stylesheet" href="/assets/layout/layout.css" />
        <link rel="stylesheet" href="/assets/icons/icon.css" />
        <style>{`:root {
  --p-bg: #0a0a0d; --p-surface: #141419; --p-ink: #edeef1; --p-muted: #9ea1ab;
  --p-accent: #2f6be6; --p-accent-ink: #ffffff; --p-action: #2f6be6; --p-action-ink: #ffffff;
  --p-inv-bg: #060608; --p-inv-surface: #101014; --p-inv-ink: #edeef1; --p-inv-muted: #9ea1ab;
  --p-inv-accent: #edeef1; --p-inv-accent-ink: #060608; --p-inv-action: #edeef1; --p-inv-action-ink: #060608;
  --font-display: "Sora", system-ui, sans-serif;
  --font-text: "Figtree", system-ui, sans-serif;
  --font-mono: "Martian Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  --display-weight: 400;
  --display-tracking: -0.035em;
  --display-tracking-xl: -0.045em;
  --ly-scale: 0.9;
}
.close__word { line-height: 1.05; overflow: visible; }
#features { overflow-x: clip; }
#features > .wrap { grid-template-columns: minmax(0, 1fr); width: min(calc(100% - 2 * var(--pad)), var(--container)); margin-inline: auto; }
#features .group { min-width: 0; }
#features .grid { min-width: 0; }
#features .mo-mq { width: 100%; max-width: 100%; overflow: hidden; }
#features .mo-mq .mo-mq__rail { max-width: 100%; }
#jobs .frame { --ratio: 72%; }
#jobs .frame, #jobs .stage { min-height: 0; }
#questions .faq__item { margin-block: 0; }
#questions .faq__item h3, #questions .faq__item p { margin-block: 0; }
#questions .faq { display: flex; flex-direction: column; gap: 12px; }
`}</style>
        <link rel="stylesheet" href="/assets/ui/base.css" />
        <link rel="stylesheet" href="/assets/ui/window/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/search/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/checklist/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/notify/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/code/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/diff-review/fragment.css" />
        <link rel="stylesheet" href="/assets/ui/chat/fragment.css" />
        <link rel="stylesheet" href="/assets/diagrams/diagram.css" />
        <link rel="modulepreload" href="/assets/moments/moments.js" />
        <link rel="modulepreload" href="/assets/moments/lib.js" />
        <link rel="modulepreload" href="/assets/moments/cursor-spotlight/moment.js" />
        <link rel="modulepreload" href="/assets/moments/marquee-row/moment.js" />
        <script
          dangerouslySetInnerHTML={{
            __html:
              "document.documentElement.classList.add('m-enter');setTimeout(()=>document.documentElement.classList.add('m-enter-done'),700)",
          }}
        />
        <noscript>
          <style>{`.hero[data-enter] :is(h1, h1 ~ *, p, .btn-row) { opacity: 1 !important; }`}</style>
        </noscript>
      </head>
      <body suppressHydrationWarning>
        {children}
        <KitBoot />
      </body>
    </html>
  );
}
