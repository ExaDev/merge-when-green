import type { Options } from "semantic-release";

type ReleaseLevel = "major" | "minor" | "patch" | false;

interface CommitType {
  readonly type: string;
  readonly release: ReleaseLevel;
  /** The heading this type's commits are listed under in the release notes and CHANGELOG.md. */
  readonly section: string;
}

/**
 * The conventional-commit types this repository accepts, and the release level each one triggers. commitlint.config.ts imports this so its type-enum rule and commit-analyzer's releaseRules below can never drift apart — a commit type either exists here, or it fails commit-msg validation and never reaches a release decision. Every type here is also listed in the release notes, so a release is never cut by a commit that its own notes omit.
 */
export const commitTypes: readonly CommitType[] = [
  { type: "feat", release: "minor", section: "Features" },
  { type: "fix", release: "patch", section: "Bug Fixes" },
  { type: "docs", release: "patch", section: "Documentation" },
  { type: "refactor", release: "patch", section: "Code Refactoring" },
  { type: "perf", release: "patch", section: "Performance Improvements" },
  { type: "test", release: "patch", section: "Tests" },
  { type: "build", release: "patch", section: "Build System" },
  { type: "ci", release: "patch", section: "Continuous Integration" },
  { type: "chore", release: "patch", section: "Chores" },
  { type: "revert", release: "patch", section: "Reverts" },
];

/**
 * Runs on push to main. Analyses commits since the last v* tag, computes the next version, generates release notes and a CHANGELOG.md entry, creates the GitHub Release and the version tag, and commits CHANGELOG.md back to main. There is no npm-publish step: this repository ships a GitHub Action, not an npm package. The final plugin, ./scripts/move-major-tag.mts, moves the moving `v1` tag to the new release afterwards, since semantic-release has no concept of that and consuming repositories already pin to `@v1`.
 */
const config: Options = {
  branches: ["main"],
  // SSH, so the release commit and tags are pushed with the deploy key the checkout configured rather than over https with a token that cannot bypass branch protection.
  repositoryUrl: "git@github.com:ExaDev/merge-when-green.git",
  plugins: [
    [
      "@semantic-release/commit-analyzer",
      {
        preset: "conventionalcommits",
        releaseRules: [
          { breaking: true, release: "major" },
          ...commitTypes.map((t) => ({ type: t.type, release: t.release })),
        ],
      },
    ],
    // conventional-changelog-conventionalcommits is a direct dependency pinned to 9.x, not left to resolve through @commitlint/config-conventional: release-notes-generator loads conventional-changelog-writer 8, and the 10.x preset needs writer 9, so it renders an error instead of notes. With 9.x, presetConfig.types lists every type in commitTypes under its section, which the angular preset cannot (it lists only feat, fix, perf and revert, so a release cut by a docs, refactor, ci or chore commit had a version header and nothing under it). The version header is always H2, so the file's only H1 stays this repository's own "# Changelog" title.
    [
      "@semantic-release/release-notes-generator",
      {
        preset: "conventionalcommits",
        presetConfig: {
          types: commitTypes.map((t) => ({ type: t.type, section: t.section })),
        },
      },
    ],
    "@semantic-release/changelog",
    // A plugin file, not an npm package: runs in the prepare step, which executes in plugin-list order, so placing it here -- after @semantic-release/changelog writes CHANGELOG.md and before @semantic-release/git commits it -- formats the generated file so it passes format:check. See the plugin's own docstring for why this is a local plugin rather than a flag on @semantic-release/changelog (which has none).
    "./scripts/format-changelog.mts",
    "@semantic-release/github",
    [
      "@semantic-release/git",
      {
        assets: ["CHANGELOG.md"],
        message: "chore(release): ${nextRelease.version} [skip ci]",
      },
    ],
    // A plugin file, not an npm dependency: referenced by path so Options.plugins' own PluginSpec type (string | [string, T]) is satisfied without a cast. See the plugin's own docstring for why this exists as local code rather than a package.
    "./scripts/move-major-tag.mts",
    // A plugin file, not an npm dependency, for the same reason. Runs after the tag move so the release it edits points at the moved tag.
    "./scripts/add-compare-link.mts",
    "./scripts/sync-major-release.mts",
  ],
};

export default config;
