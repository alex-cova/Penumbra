"use client";

import { useEffect } from "react";

export function SiteEffects() {
  useEffect(() => {
    const navToggle = document.querySelector<HTMLButtonElement>(".nav-toggle");
    const navMenu = document.getElementById("nav-menu");
    const cleanups: Array<() => void> = [];

    if (navToggle && navMenu) {
      const onToggle = () => {
        const isOpen = navToggle.getAttribute("aria-expanded") === "true";
        navToggle.setAttribute("aria-expanded", String(!isOpen));
        navToggle.setAttribute("aria-label", isOpen ? "Open menu" : "Close menu");
        navMenu.classList.toggle("is-open", !isOpen);
      };
      navToggle.addEventListener("click", onToggle);
      cleanups.push(() => navToggle.removeEventListener("click", onToggle));

      const links = navMenu.querySelectorAll("a");
      const onLink = () => {
        navToggle.setAttribute("aria-expanded", "false");
        navToggle.setAttribute("aria-label", "Open menu");
        navMenu.classList.remove("is-open");
      };
      links.forEach((link) => link.addEventListener("click", onLink));
      cleanups.push(() => links.forEach((link) => link.removeEventListener("click", onLink)));
    }

    const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const revealElements = document.querySelectorAll(".reveal");

    if (!prefersReducedMotion && revealElements.length > 0) {
      const observer = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) {
              entry.target.classList.add("is-visible");
              observer.unobserve(entry.target);
            }
          });
        },
        { threshold: 0.15, rootMargin: "0px 0px -40px 0px" },
      );
      revealElements.forEach((element) => observer.observe(element));
      cleanups.push(() => observer.disconnect());
    } else {
      revealElements.forEach((element) => element.classList.add("is-visible"));
    }

    document.querySelectorAll<HTMLButtonElement>("[data-copy-target]").forEach((button) => {
      const onCopy = async () => {
        const targetId = button.getAttribute("data-copy-target");
        const target = targetId ? document.getElementById(targetId) : null;
        if (!target) return;

        const text = target.textContent || "";
        try {
          await navigator.clipboard.writeText(text);
          button.classList.add("is-copied");
          const originalLabel = button.textContent;
          button.textContent = "Copied";
          window.setTimeout(() => {
            button.textContent = originalLabel;
            button.classList.remove("is-copied");
          }, 1600);
        } catch {
          button.textContent = "Failed";
          window.setTimeout(() => {
            button.textContent = "Copy";
          }, 1600);
        }
      };
      button.addEventListener("click", onCopy);
      cleanups.push(() => button.removeEventListener("click", onCopy));
    });

    return () => {
      cleanups.forEach((cleanup) => cleanup());
    };
  }, []);

  return null;
}
