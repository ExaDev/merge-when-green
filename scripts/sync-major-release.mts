import { execFileSync } from "node:child_process";
import type { SuccessContext } from "semantic-release";

/** semantic-release's own SuccessContext types `logger` as `Signale<...>`, but the `signale` package ships no type declarations of its own, so it surfaces as an unsafe `any` wherever `context.logger` is used. Overriding just that one field with the narrow shape this file calls avoids relying on the broken upstream type. */
type TypedSuccessContext = Omit<SuccessContext, "logger"> & {
  readonly logger: { readonly log: (message: string) => void };
};

/**
 * semantic-release plugin, referenced by path from release.config.ts. Keeps one GitHub Release, named after the moving major tag (v1, v2, ...), pointing at that tag and carrying the latest release's notes. The Marketplace listing is switched on per release, by hand, in the web UI; this release is the one ticked there, so it is the single listing that follows every new version once the tag moves. It is never marked Latest, so the exact version's release stays the repository's latest.
 *
 * Runs in the `success` step after move-major-tag.mts, which has already pushed the moved tag.
 */
export function success(
  _pluginConfig: unknown,
  context: TypedSuccessContext,
): void {
  const { nextRelease, logger, cwd, env } = context;
  const majorVersionSegment = nextRelease.version.split(".")[0];
  if (majorVersionSegment === undefined) {
    throw new Error(
      `Could not parse a major version from "${nextRelease.version}".`,
    );
  }
  const major = `v${majorVersionSegment}`;
  const notes = `Moving release for ${major}, currently ${nextRelease.gitTag}.\n\n${nextRelease.notes ?? ""}`;

  const gh = (...args: readonly string[]): Buffer =>
    execFileSync("gh", args, {
      cwd,
      env,
      stdio: ["ignore", "pipe", "inherit"],
    });

  let exists = true;
  try {
    gh("release", "view", major);
  } catch {
    exists = false;
  }

  if (exists) {
    gh(
      "release",
      "edit",
      major,
      "--title",
      major,
      "--notes",
      notes,
      "--latest=false",
    );
    logger.log(`Updated the ${major} release to ${nextRelease.gitTag}`);
  } else {
    gh(
      "release",
      "create",
      major,
      "--verify-tag",
      "--title",
      major,
      "--notes",
      notes,
      "--latest=false",
    );
    logger.log(`Created the ${major} release at ${nextRelease.gitTag}`);
  }
}
