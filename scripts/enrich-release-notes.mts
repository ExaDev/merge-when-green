import { execFileSync } from "node:child_process";
import type { SuccessContext } from "semantic-release";

/** semantic-release's own SuccessContext types `logger` as `Signale<...>`, but the `signale` package ships no type declarations of its own, so it surfaces as an unsafe `any` wherever `context.logger` is used. Overriding just that one field with the narrow shape this file calls avoids relying on the broken upstream type. */
type TypedSuccessContext = Omit<SuccessContext, "logger"> & {
  readonly logger: { readonly log: (message: string) => void };
};

/**
 * semantic-release plugin, referenced by path from release.config.ts. Appends GitHub's own generated release notes (the pull requests merged since the previous release, the new contributors and the compare link) to the release semantic-release just published, below the changelog entry it already holds, so a release carries both.
 *
 * Runs in the `success` step, after the release exists and before sync-major-release.mts, which copies the finished body to the major tag's release.
 */
export function success(
  _pluginConfig: unknown,
  context: TypedSuccessContext,
): void {
  const { nextRelease, lastRelease, logger, cwd, env } = context;

  const gh = (...args: readonly string[]): string =>
    execFileSync("gh", args, {
      cwd,
      env,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    });

  const generated = gh(
    "api",
    "repos/{owner}/{repo}/releases/generate-notes",
    "-f",
    `tag_name=${nextRelease.gitTag}`,
    "-f",
    `previous_tag_name=${lastRelease.gitTag}`,
    "--jq",
    ".body",
  ).trim();
  const changelog = gh(
    "release",
    "view",
    nextRelease.gitTag,
    "--json",
    "body",
    "--jq",
    ".body",
  ).trim();

  gh(
    "release",
    "edit",
    nextRelease.gitTag,
    "--notes",
    `${changelog}\n\n---\n\n${generated}`,
  );
  logger.log(`Added GitHub's generated notes to ${nextRelease.gitTag}`);
}
