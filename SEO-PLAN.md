# HeyVedu SEO plan and article skeletons

Research date: 29 September 2026. Planning document; no website changes or publishing performed.

## Recommendation

Start with **free, open-source, offline dictation for Apple-silicon Macs**, aimed at technical users willing to build from source. Publish practical setup and privacy evidence, then focused competitor comparisons. Expand into broader “best dictation app” searches after gathering firsthand tests.

Privacy and open source alone are not unique: VoiceInk and other alternatives already compete on them. HeyVedu's useful combination is a free source build, local speech recognition plus local cleanup by default, no stored dictation history, and a small push-to-talk workflow. Demonstrate this combination rather than claiming to be the only private option.

Success means relevant Google visitors who proceed to installation instructions, not merely more article traffic. Installation friction is a conversion constraint: the current product has no signed binary release.

## Research scope and limits

Reviewed official Wispr Flow, Superwhisper, and VoiceInk pages; sampled searches for offline Mac dictation and free Wispr Flow alternatives; inspected HeyVedu's local homepage, README, robots.txt, sitemap, and deployment configuration. Search samples show competing content formats, not verified Google positions or keyword demand.

No Search Console, analytics, backlink database, paid keyword tool, or competitor traffic data was available. Priorities below are editorial judgments based on intent and product fit, not measured search volume or difficulty. Live HeyVedu retrieval failed in this research environment; local findings do not establish production behavior. Competitor HTTP headers, canonicals, schema, and performance were not verified. Excluded similarly named unofficial sites such as wisprfiow.com from competitor attribution.

## What competitors are doing

| Competitor | Observable approach | Likely purpose — inference | What HeyVedu should adapt |
| --- | --- | --- | --- |
| Wispr Flow | A category comparison page, individual product comparisons, and a separate editorial blog covering product and engineering topics | Reach category researchers and people comparing named products; technical posts can support credibility | Create focused comparison pages alongside original technical evidence |
| Superwhisper | A `/vs` hub, workflow hub, category landing pages, platform pages, and free browser tools | Cover different search intents and connect discovery pages to app downloads | Adopt hub-to-detail linking and useful workflow pages; only cover supported platforms |
| VoiceInk | A Mac dictation roundup, blog, documentation, source-code links, demonstrations, and pricing on the homepage | Help people evaluate tools, resolve setup questions, and understand purchase tradeoffs | Put requirements and evidence near calls to action; connect comparison guides to installation help |

Wispr's [category comparison](https://wisprflow.ai/best-dictation-apps), [Monologue comparison](https://wisprflow.ai/post/wispr-flow-vs-monologue), and [blog](https://wisprflow.ai/blog) illustrate these distinct page types. Do not reuse its vendor-written assessments as neutral evidence about other products. Older year labels and fast-changing features require fresh checks when writing our comparisons.

Superwhisper provides a clear [comparison hub](https://superwhisper.com/vs), [workflow hub](https://superwhisper.com/use-cases), and [dictation landing page](https://superwhisper.com/dictation-software). The latter links to browser dictation and typing-speed tools. This suggests a discovery-to-product path; it does not prove those pages drive significant traffic.

VoiceInk's [Mac app roundup](https://tryvoiceink.com/best-dictation-apps) includes use-case picks, a comparison table, author and update information, limitations, and links to deeper comparisons. Its [homepage](https://tryvoiceink.com/) combines demonstrations, testimonials, pricing, FAQs, and source links, while its [documentation](https://tryvoiceink.com/docs/introduction) supports setup. These are useful structural examples, not evidence that its product is objectively best.

The sampled alternatives searches also surfaced many smaller vendors publishing similar listicles. Treat the broad “Wispr Flow alternatives” topic as crowded; a generic rewritten list is unlikely to distinguish HeyVedu.

## HeyVedu's current gaps

| Local observation | Implication | Recommended action |
| --- | --- | --- |
| `sitemap.xml` contains only the homepage | No separate discovery pages for comparison or setup intent | Add a small, linked set of substantive pages |
| Static HTML contains readable product copy, title, and description | A useful foundation already exists | Keep content accessible in initial HTML |
| H1 is “Speak freely. Nothing leaves your Mac.” | Strong benefit statement, but broad wording and privacy qualification is distant | Make the category explicit and qualify the default local workflow nearby |
| No canonical link or JSON-LD in `index.html` | Missing explicit preferred-URL and structured meaning signals | Add a self-canonical; use accurate, applicable structured data |
| Checked-in Nginx config serves both www and apex; HTTP redirect preserves host | Possible duplicate host versions if production matches | Verify live behavior, then redirect variants to `https://heyvedu.com/` |
| README contains detailed installation and privacy information | Useful answers are primarily outside the marketing site | Publish maintained setup and privacy pages on the domain |
| Source build, English only, Apple silicon, macOS 26+ | Many broad-search visitors cannot use it immediately | Show requirements near installation CTAs and in comparisons |

Suggested homepage title: **Free Offline Dictation for Mac | HeyVedu**.

Suggested H1: **Free, open-source dictation for Mac**.

Suggested supporting sentence: “Hold a shortcut, speak, and paste polished English text into your app. Speech recognition and default cleanup run on your Mac, offline after setup.”

Suggested meta description: “Free, open-source dictation for Apple-silicon Macs. Speech recognition and default cleanup run locally. English only; macOS 26+. Build from source.”

Keep “Install from source” as the CTA until a downloadable release exists. Explain that optional online cleanup sends transcript text through the user's configured CLI provider. Avoid universal “nothing ever leaves your Mac” claims.

## Keyword and page map

Each row owns a distinct primary intent. These are proposed targets, not validated demand estimates. Keep synonyms together; do not make separate pages merely for “voice typing,” “speech to text,” and “dictation.”

| Priority | Page | Primary query / intent | Conversion |
| --- | --- | --- | --- |
| P0 | `/` | free offline dictation for Mac; product discovery | Open installation guide |
| P0 | `/docs/install/` | install HeyVedu; complete setup | Follow source-build instructions |
| P0 | `/privacy/` | HeyVedu privacy; evaluate data handling | Review source or install |
| P1 | `/guides/offline-dictation-mac/` | how to dictate offline on Mac | Complete offline setup |
| P1 | `/compare/wispr-flow/` | free offline Wispr Flow alternative for Mac | Assess fit and install |
| P1 | `/compare/superwhisper/` | Superwhisper alternative for Mac | Assess simpler workflow |
| P1 | `/compare/voiceink/` | VoiceInk vs HeyVedu | Assess source-build tradeoff |
| P1 | `/guides/local-vs-cloud-dictation/` | local vs cloud dictation privacy | Review privacy details |
| P2 | `/guides/dictation-for-developers/` | voice dictation for developers on Mac | Try a documented workflow |
| P2 | `/guides/best-open-source-dictation-mac/` | best open-source dictation for Mac | Choose a suitable product |
| P2 | `/research/mac-dictation-benchmark/` | Mac dictation speed and accuracy comparison | Inspect evidence; try app |

Publish `/guides/` and `/compare/` as useful navigation hubs once there are several pages to list. Homepage links to hubs and setup; each article links to its hub, one relevant comparison, and installation or privacy. Use descriptive anchors such as “set up offline dictation on Mac.”

Do not publish duplicate `/wispr-flow-alternative/` and `/compare/wispr-flow/` pages for the same intent. Avoid Windows, Android, multilingual, medical-compliance, and meeting-transcription landing pages for capabilities HeyVedu does not offer.

## 90-day execution plan

| Period | Work | Owner role | Completion evidence |
| --- | --- | --- | --- |
| Days 1–14 | Verify Search Console domain access; establish baseline; verify live crawlability, redirects, canonical, and sitemap; revise homepage metadata; publish installation and privacy pages | Developer / founder | URL inspection succeeds; useful pages linked; source-build flow documented |
| Days 15–30 | Publish offline setup guide and Wispr comparison after testing; add hubs and internal links; record a real workflow demo | Founder / writer | Two original pages with reproducible steps and checked sources |
| Days 31–60 | Publish Superwhisper and VoiceInk comparisons, local/cloud guide, and developer workflow; gather benchmark data | Writer + product tester | Four pages with evidence; benchmark protocol and raw results ready |
| Days 61–90 | Publish benchmark and open-source roundup; refresh pages based on Search Console queries; share useful research with relevant communities and editors | Founder / writer | Two evidence-led pages, documented query review, outreach log |

If testing capacity is limited, publish fewer strong pages. Product work toward a signed, notarized installer should run alongside content when feasible, because making installation easier can improve the value of every organic visit.

## Article skeletons

### 1. How to Use Offline Dictation on Mac

- **URL:** `/guides/offline-dictation-mac/`
- **Intent:** Complete a task; primary query “offline dictation Mac.”
- **Meta description:** “Set up offline dictation on an Apple-silicon Mac. Check requirements, download models, test without internet, and troubleshoot text insertion.”
- **Opening:** Give the direct answer and distinguish first-time downloads from subsequent offline use. State HeyVedu requirements immediately.
- **H2: What works offline, and what needs a connection?** Separate recognition, cleanup, model downloads, and the destination app.
- **H2: Check your Mac before installing.** Hardware, OS, Xcode, storage, language, source-build requirement.
- **H2: Install HeyVedu and download the models.** Link to the maintained installation guide; avoid duplicating every command.
- **H2: Make your first dictation.** Permissions, Control + Option, listening indicator, release, paste.
- **H2: Verify offline operation.** After setup, disconnect networking and dictate into a local editor. Explain what this functional test does and does not prove.
- **H2: Fix common problems.** Permissions, Bluetooth delay, missing models, paste-blocking fields.
- **H2: When another option fits better.** Older OS, other languages, or a ready-made installer.
- **Evidence:** Actual setup screenshots, short offline demo, machine and version details.
- **Links / CTA:** Installation guide, privacy page, local/cloud guide. CTA: “Check requirements and install from source.”

### 2. HeyVedu vs Wispr Flow: A Free Offline Mac Alternative?

- **URL:** `/compare/wispr-flow/`
- **Intent:** Decide whether to switch; target “free offline Wispr Flow alternative Mac.”
- **Meta description:** “Compare HeyVedu and Wispr Flow on offline use, installation, privacy, cleanup, and platform support. See which fits your Mac workflow.”
- **Opening:** Say who HeyVedu suits and who should prefer a managed product. Disclose that HeyVedu publishes the comparison.
- **H2: Quick verdict by user need.** Technical Mac user, cross-device user, multilingual user, simple installation seeker.
- **H2: Features and requirements at a glance.** Table with platform, minimum OS, language, installation, pricing model, audio processing, text cleanup, and retention. Date and source volatile fields.
- **H2: What happens to your audio and text?** Use each vendor's own current documentation; distinguish processing from retention.
- **H2: The same three dictation tasks.** Email, developer prompt, self-correction; show actual outputs if tested.
- **H2: What you gain and give up by switching.** Include HeyVedu's source build, English-only support, and no history.
- **H2: How to try HeyVedu alongside your current tool.** No invented settings-import feature.
- **H2: Questions before switching.** Offline after setup? Signed installer? Other devices?
- **Evidence:** Dated official sources, test versions/settings, unedited output examples. Label untested dimensions as documentation-based.
- **Links / CTA:** Offline guide, privacy, install. CTA: “See whether your Mac meets the requirements.”

### 3. HeyVedu vs Superwhisper: Simple Dictation or More Controls?

- **URL:** `/compare/superwhisper/`
- **Intent:** Evaluate a Superwhisper alternative for Mac.
- **Meta description:** “Compare HeyVedu and Superwhisper for local Mac dictation: model choices, cleanup, setup, pricing, and the features each workflow needs.”
- **Opening:** Both can involve local processing; do not present offline capability as exclusive to HeyVedu.
- **H2: Which workflow are you buying into?** Narrow push-to-talk versus configurable product; verify current features.
- **H2: Requirements, pricing, and installation.** Distinguish free source availability from a packaged app and free-tier allowances.
- **H2: Recognition and cleanup are separate stages.** Explain HeyVedu's Parakeet recognition and default S1-mini cleanup; credit S1-mini to Superwhisper.
- **H2: Local configuration and privacy.** Record the actual model/settings tested in each app.
- **H2: Where each tool is a better fit.** Explicitly cover HeyVedu limitations.
- **H2: Side-by-side examples and test conditions.** Publish only after obtaining outputs.
- **H2: Trying HeyVedu without replacing your existing setup.** Link to installation.
- **Evidence:** Screenshots of model settings, configuration table, task outputs, source links.
- **Links / CTA:** Benchmark when available, local/cloud guide, install.

### 4. HeyVedu vs VoiceInk: Which Local Mac Dictation Workflow Fits?

- **URL:** `/compare/voiceink/`
- **Intent:** A focused product comparison; do not assume high search demand.
- **Meta description:** “Compare HeyVedu and VoiceInk on installation, local processing, cleanup controls, and daily dictation. Understand the source-build tradeoff.”
- **Opening:** Both have open-source positioning; “open source” does not by itself distinguish HeyVedu.
- **H2: Quick fit comparison.** Installation effort, requirements, controls, support, and available workflows.
- **H2: Free source builds and paid convenience.** Verify each current distribution and license rather than equating paid with closed source.
- **H2: What stays local under each configuration?** Separate voice processing, optional enhancement, context access, and stored history using current first-party sources.
- **H2: Daily dictation examples.** Same prompts, actual outputs, useful limitations.
- **H2: Customization versus a small default workflow.** Check vocabulary behavior; HeyVedu's S1-mini currently ignores its vocabulary list.
- **H2: Reasons to choose either app.** Include OS compatibility and installation comfort.
- **Evidence:** Current official documentation and hands-on settings captures.
- **Links / CTA:** Privacy, install, open-source roundup when available.

### 5. Local vs Cloud Dictation: Where Do Your Words Go?

- **URL:** `/guides/local-vs-cloud-dictation/`
- **Intent:** Understand privacy and deployment tradeoffs.
- **Meta description:** “Learn how local and cloud dictation handle audio, transcript cleanup, storage, and model downloads, with a checklist for comparing apps.”
- **Opening:** Processing location, retention, and training use are different questions.
- **H2: Follow the audio from microphone to text.** Simple diagram.
- **H2: Follow the text through cleanup and insertion.** Local recognition does not establish local cleanup.
- **H2: What offline, private, and zero retention actually describe.** Define without assigning unsupported guarantees.
- **H2: Questions to ask about any dictation app.** Audio transmission, text transmission, storage, training, diagnostics, clipboard, destination app.
- **H2: HeyVedu's default and optional paths.** Default local cleanup; optional CLI providers; clipboard and clipboard-manager boundaries.
- **H2: How to check a configuration.** Source inspection, network observation, and offline test; acknowledge each method's limits.
- **Evidence:** Reviewed code references and a truthful data-flow diagram. Do not infer regulatory compliance.
- **Links / CTA:** Detailed privacy page, offline guide. CTA: “Inspect HeyVedu's data flow and source.”

### 6. Voice Dictation for Developers on Mac: Prompts, PRs, and Notes

- **URL:** `/guides/dictation-for-developers/`
- **Intent:** Apply dictation to a real developer workflow.
- **Meta description:** “Use Mac dictation for coding prompts, pull request drafts, and engineering notes. Follow tested workflows and learn where typing still helps.”
- **Opening:** Focus on natural-language work developers already do, with exact app versions tested.
- **H2: Set up push-to-talk in your editor.** Test the target text field and shortcut behavior.
- **H2: Dictate a coding prompt.** Speak goal, context, constraints, and acceptance criteria; show a real example.
- **H2: Draft a pull request description.** Spoken explanation to editable draft.
- **H2: Capture debugging notes.** Review names and identifiers.
- **H2: Where voice makes mistakes.** Syntax, paths, symbols, proper nouns; never claim reliable code generation from dictation alone.
- **H2: Keep the privacy boundary clear.** The destination editor or AI service may send pasted text elsewhere, even if dictation is local.
- **Evidence:** Screen recording in one or two verified apps; label system-wide paste behavior accurately, without implying a native integration.
- **Links / CTA:** Install, offline guide, privacy. CTA: “Try dictating one engineering note.”

### 7. Open-Source Dictation Apps for Mac: A Practical Comparison

- **URL:** `/guides/best-open-source-dictation-mac/`
- **Intent:** Evaluate a shortlist, rather than a single vendor.
- **Meta description:** “Compare open-source Mac dictation apps by local processing, installation, hardware support, cleanup, and licensing. Choose a workflow that fits.”
- **Opening:** Explain selection criteria and publisher affiliation; do not automatically rank HeyVedu first.
- **H2: Quick picks by requirement.** Based on verified facts and tests.
- **H2: How the tools were selected and evaluated.** Repository/license checks, maintenance, installability, local pipeline, supported hardware.
- **H2: Comparison table.** Include HeyVedu and VoiceInk; evaluate candidates such as Handy and OpenWhispr before inclusion.
- **H2: Individual app profiles.** Consistent H3s: best fit, strengths, limitations, installation, verified source.
- **H2: Open source does not automatically mean offline.** Distinguish app license, model license, hosted services, and binary pricing.
- **H2: Choose by workflow.** Developer willing to build, ready-made installer seeker, older hardware, broader language needs.
- **Evidence:** Current official repositories, licenses, first-party docs, install tests; date every review.
- **Links / CTA:** Relevant comparisons and setup. Recommend another tool when it fits better.

### 8. Mac Dictation Benchmark: Accuracy, Cleanup, and Time to Paste

- **URL:** `/research/mac-dictation-benchmark/`
- **Intent:** Provide original evidence people can reference.
- **Meta description:** “A reproducible Mac dictation comparison covering recognition errors, cleanup changes, and time to paste. Includes settings, test prompts, and results.”
- **Opening:** No winners or numeric claims until tests have run; disclose publisher affiliation and sample limits.
- **H2: Hardware, versions, and exact configurations.** Models, cleanup settings, microphone, network, and cold/warm state.
- **H2: Test set and protocol.** Use an original or licensed set of at least 30 utterances across messages, technical vocabulary, and self-corrections. Include more than one speaker if making broader claims.
- **H2: Recognition accuracy.** Compare raw output against reference text; document normalization and word-error-rate calculation.
- **H2: Cleanup quality.** Separately assess preserved meaning, corrections, punctuation, and unwanted rewrites. WER alone is unsuitable for intentional rewriting.
- **H2: Time from release to pasted text.** Repeated runs; report sample size, median, and spread. Separate cold starts and downloaded-model preparation.
- **H2: Failure cases and offline behavior.** Publish misses as well as successes.
- **H2: Results and reproducibility files.** Tables, original audio where consent permits, reference texts, anonymized outputs, and a CSV.
- **H2: What these results cannot establish.** Other devices, accents, languages, environments, and product updates.
- **Links / CTA:** Relevant product comparisons and setup. CTA: “Inspect the test data or try the same prompts.”

## Publication and technical requirements

Give each page a unique descriptive title, clear H1, short answer near the top, relevant internal links, and a factual meta description. Use natural terms rather than keyword repetition. Google recommends useful original content and descriptive titles and headings; it does not prescribe an ideal article word count. See [Search Essentials](https://developers.google.com/search/docs/essentials) and [helpful-content guidance](https://developers.google.com/search/docs/fundamentals/creating-helpful-content).

Use real author names, a maintained author/about page, review dates, official citations, and screenshots or demonstrations. Only call a comparison “tested” after testing. Review prices and requirements before publication and on meaningful product changes.

For implementation, use static pages such as `guides/offline-dictation-mac/index.html` that fit the existing deployment. A CMS migration is unnecessary for the first batch. Verify 200 responses, consistent slash/host redirects, self-canonicals, working mobile navigation, crawlable links, and genuine 404 responses. Include only canonical indexable pages in the sitemap, with truthful modification dates. A sitemap helps discovery but does not guarantee indexing or ranking: [Google's indexing FAQ](https://developers.google.com/search/help/crawling-index-faq).

Use Article and BreadcrumbList markup where appropriate; consider accurate SoftwareApplication markup on the product page against Google's current eligibility requirements. Match markup to visible facts, never invent ratings, and validate before publishing. Rich-result appearance is not guaranteed. See [Google's structured-data guide](https://developers.google.com/search/docs/appearance/structured-data/intro-structured-data).

Keep FAQs when they answer useful questions, but do not spend time adding FAQ schema for a Google rich-result benefit: Google's current changelog says FAQ rich results stopped appearing in May 2026. It also says llms.txt does not improve Google visibility or rankings. See the [Google Search documentation updates](https://developers.google.com/search/updates).

Measure mobile performance and Core Web Vitals before prescribing fixes; no performance score was established in this audit. Compress screenshots, reserve image dimensions, and avoid making video embeds delay the page's main content.

## Authority and distribution

Use the benchmark, offline demonstration, and technical privacy explanation as reasons for others to cite HeyVedu. Keep the GitHub project description and website link consistent. Consider accurate submissions to relevant open-source and software directories, and offer reproducible findings to Mac productivity writers and developer communities. Disclose affiliation and follow each community's rules. These are planned activities; no outreach was sent.

Avoid purchased ranking links, mass directory submissions, and repetitive promotional comments. Google's [site-position guidance](https://developers.google.com/search/help/site-position-in-search-faq) recommends earning links with useful content and warns about unnatural link schemes.

## Measurement and decision rules

Baseline the current site before publication. In Search Console, track Google impressions, clicks, CTR, and position by page, query group, country, and device; separate branded from non-branded queries. Compare 28-day periods while accounting for small sample sizes and page age.

Track privacy-conscious website events for installation-guide opens and outbound source-install clicks, without collecting dictated content. These clicks are intent proxies, not confirmed installations. Do not add app telemetry merely to satisfy an SEO dashboard.

Operational target: the homepage improvements, two foundational pages, eight evidence-supported content pages, and their navigation hubs within 90 days if testing capacity permits. There is no justified traffic or ranking forecast without a baseline.

- **Not indexed:** Inspect crawl access, canonical selection, internal links, and page usefulness before writing more pages.
- **Impressions but weak CTR:** Check actual queries, intent match, and competing snippets; refine title and description without promising unsupported features.
- **Clicks but few installation-guide opens:** Improve fit, requirements visibility, demonstration, and CTA placement.
- **Installation interest but adoption unknown:** Treat source-build friction as a product issue to investigate; do not equate clicks with success.
- **Multiple pages competing for the same intent:** Differentiate their purpose or consolidate with redirects.
- **A small relevant query cluster gains traction:** Improve that cluster with original evidence before expanding into unrelated topics.

The first publishing sequence should be installation and privacy foundations, then the offline guide and Wispr comparison. That creates a useful path from discovery to evaluation to setup.
