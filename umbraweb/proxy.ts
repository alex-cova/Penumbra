import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

export function proxy(request: NextRequest) {
  const host = request.headers.get("host")?.split(":")[0];
  if (host !== "www.umbraeditor.com") return NextResponse.next();

  const url = request.nextUrl.clone();
  url.protocol = "https:";
  url.hostname = "umbraeditor.com";
  return NextResponse.redirect(url, 308);
}

export const config = {
  matcher: "/:path*",
};
