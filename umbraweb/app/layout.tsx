import type { Metadata, Viewport } from "next";
import { SiteEffects } from "./site-effects";
import "./globals.css";

const title = "Penumbra - macOS code editor framework";
const description =
  "Umbra is a lightweight macOS code editor with native Java and Gradle support, an in-app HTTP client, Git integration, and Markdown preview. Built on the Penumbra text engine.";
const socialTitle = "Penumbra and Umbra - macOS code editor";
const socialDescription =
  "Fast folder editing with Java intelligence, Gradle sync, .http request files, tree-sitter highlighting, and a split-pane workbench.";
const siteUrl = "https://umbraeditor.com";
const socialImage =
  "https://raw.githubusercontent.com/alex-cova/Penumbra/main/Screenshots/banner.png";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title,
  description,
  alternates: { canonical: "/" },
  icons: {
    icon: { url: "/umbra.png", type: "image/png" },
    apple: "/umbra.png",
  },
  openGraph: {
    url: siteUrl,
    title: socialTitle,
    description: socialDescription,
    images: [socialImage],
  },
  twitter: {
    card: "summary_large_image",
    images: [socialImage],
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#090b10" },
    { media: "(prefers-color-scheme: light)", color: "#f6f7f9" },
  ],
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <SiteEffects />
        {children}
      </body>
    </html>
  );
}
