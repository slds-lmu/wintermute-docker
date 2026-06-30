# Install the R packages baked into the slds-tools default image.
# Run from the Dockerfile via `Rscript install_packages.R`.
#
# Uses pak to resolve and install binary packages from PPM only.
#
# Repository policy:
#   - PPM (Posit Public Package Manager) is the SOLE repo: a CRAN mirror serving
#     pre-compiled noble binaries from a date-pinned snapshot (not `latest`).
#     Bump the date below to pick up newer R packages; see README for the
#     full rationale and bump procedure.
# We install HARD dependencies only (Depends / Imports / LinkingTo), via
# dependencies = NA below — NOT Suggests. Reason: every hard dependency of the
# list is on CRAN and therefore in PPM, but some *Suggests* are not. Notably
# several mlr3 packages suggest mlr3proba, which was removed from CRAN and now
# lives only on the (un-date-pinned) mlr-org r-universe; installing Suggests
# (dependencies = TRUE) drags mlr3proba into the solve and makes the whole
# PPM-only resolution fail. To bake in a specific suggested extra that *is* on
# PPM, add it explicitly to `pkgs` below rather than enabling all Suggests.
#
# The PPM-only rule governs the MAIN package set (`pkgs`): we deliberately keep
# r-universe and source-only fallbacks (e.g. cloud.r-project.org) out of it, so the
# main solve stays date-pinned and any "package missing on Linux noble" condition
# surfaces as a hard pak error rather than a slow source compile that may also fail.
# The ONE documented exception is the non-PPM block at the very bottom: a couple of
# packages the i2ml lecture uses in active slides that simply are not on CRAN/PPM
# (mlr3extralearners, vistool). Those install from non-PPM sources (mlr-org r-universe
# and GitHub, respectively) in a separate, clearly-marked step and therefore float
# OUTSIDE the date pin — see that block (and its system-dependency caveat).
#
# Failure handling: pak::pak() raises a hard error (non-zero R exit) on
# resolution / install failure, but we still post-check installed.packages()
# defensively so a future pak release that downgrades errors to warnings
# still trips this layer.

Sys.setenv(NOT_CRAN = "true")
install.packages(
    "pak",
    repos = sprintf(
        "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
        .Platform$pkgType, R.Version()$os, R.Version()$arch
    )
)
# Repair pak's CA bundle so the NON-PPM resolution (GitHub for vistool, r-universe
# for mlr3extralearners, in the extra step at the bottom) can do TLS.
#
# Mechanism (verified against pak's source): pak does that resolution over its OWN
# embedded libcurl. At install time pak's embed_ca_certs() DOWNLOADS
# https://curl.se/ca/cacert.pem into <pak>/curl-ca-bundle.crt, and in its worker
# subprocess `.onLoad` points libcurl's CAINFO at that file
# (options(async_http_cainfo = system.file(package="pak", "curl-ca-bundle.crt"))).
# In this build that curl.se download is unreliable and leaves a file libcurl
# cannot load, so every non-PPM HTTPS query dies with "error setting certificate
# verify locations" → "Cannot query GitHub, are you offline?". (CURL_CA_BUNDLE does
# NOT help — the worker's explicit CAINFO overrides it; nor does deleting the file
# reliably, since that just falls back to libcurl's compiled default.)
#
# Fix: overwrite that cert with the always-present, valid system CA bundle
# (ca-certificates). Empirically a valid bundle at this exact path makes the
# GitHub/r-universe resolution succeed. UNCONDITIONAL overwrite is the point: the
# broken file embed_ca_certs leaves already exists, so a "create only if missing"
# guard would skip it (the bug in a previous attempt). We define this as a
# function and call it BOTH here and again immediately before the non-PPM solve
# (belt-and-suspenders, in case anything rewrites the file in between), and it
# prints a loud confirmation + sanity-checks the result so a build log shows
# unambiguously that the repair ran and produced a valid bundle.
repair_pak_ca <- function() {
    sys_ca <- "/etc/ssl/certs/ca-certificates.crt"
    pak_ca <- file.path(find.package("pak"), "curl-ca-bundle.crt")
    if (!file.exists(sys_ca)) {
        stop("system CA bundle missing at ", sys_ca,
             " — is the ca-certificates package installed?", call. = FALSE)
    }
    if (!file.copy(sys_ca, pak_ca, overwrite = TRUE)) {
        stop("could not install system CA bundle into ", pak_ca, call. = FALSE)
    }
    # Sanity-check the result is actually a PEM bundle, not a stub/error page.
    head <- readLines(pak_ca, n = 40, warn = FALSE)
    if (!any(grepl("BEGIN CERTIFICATE", head, fixed = TRUE))) {
        stop("installed pak CA bundle at ", pak_ca,
             " does not look like a PEM bundle", call. = FALSE)
    }
    message(sprintf(
        "[install_packages.R] pak CA bundle repaired: %s -> %s (%d bytes)",
        sys_ca, pak_ca, file.size(pak_ca)))
}
repair_pak_ca()
# Make PPM the SOLE repo by REPLACING the repos option outright, rather than
# pak::repo_add() which only appends PPM and leaves the default CRAN entry in
# place — that residual entry could let a package missing from the PPM snapshot
# fall back to a CRAN source compile, the exact behavior the policy above forbids.
# (pak has no repo_set/repo_rm; setting options(repos=) is the supported way, and
# is the canonical Posit/rocker pattern for the __linux__ binary URL.) pak reads
# getOption("repos"), so this single PPM entry is the only repo it resolves against.
options(
    repos = c(
        PPM = "https://packagemanager.posit.co/cran/__linux__/noble/2026-06-21"
    )
)
pkgs <- c(
    # --- general data-science / dev toolkit ---
    "tidyverse",    # tidyverse: meta-pkg of dplyr/ggplot2/tidyr/readr — standard toolkit
    "data.table",   # data.table: fast in-memory tabular data manipulation
    "ggplot2",      # ggplot2: grammar-of-graphics plotting (also bundled in tidyverse)
    "knitr",        # knitr: dynamic report generation (Rnw / Rmd weaving)
    "devtools",     # devtools: package-development helpers (install_github, document, check)
    # --- mlr3 ecosystem ---
    "mlr3",            # mlr3: core machine-learning framework (tasks, learners, resampling)
    "mlr3misc",        # mlr3misc: internal helper functions shared across the ecosystem
    "paradox",         # paradox: parameter spaces / hyperparameter definitions
    "mlr3data",        # mlr3data: example datasets and tasks
    "mlr3cluster",     # mlr3cluster: clustering learners and tasks
    "mlr3filters",     # mlr3filters: feature-filter methods for feature selection
    "mlr3fselect",     # mlr3fselect: wrapper feature selection
    "mlr3hyperband",   # mlr3hyperband: Hyperband / successive-halving tuners
    "mlr3inferr",      # mlr3inferr: inference on generalization error
    "mlr3learners",    # mlr3learners: extra learners (xgboost, ranger, glmnet, lightgbm, ...)
    "mlr3mbo",         # mlr3mbo: model-based (Bayesian) optimization
    "mlr3pipelines",   # mlr3pipelines: ML pipelines / preprocessing graphs
    "mlr3tuning",      # mlr3tuning: hyperparameter tuning
    "mlr3tuningspaces",# mlr3tuningspaces: predefined tuning search spaces
    "mlr3viz",         # mlr3viz: autoplot visualizations for mlr3 objects
    "bbotk",           # bbotk: black-box optimization toolkit (optimizer foundation under mlr3tuning)
    "mlr3oml",         # mlr3oml: OpenML integration (fetch tasks/datasets from openml.org)
    "mlr3measures",    # mlr3measures: standalone performance measures (used directly)
    # --- plotting / visualization helpers ---
    "gridExtra",       # gridExtra: arrange multiple grid/ggplot graphics on a page
    "patchwork",       # patchwork: compose ggplots with +/|/ operators
    "cowplot",         # cowplot: publication-style ggplot themes + plot composition
    "GGally",          # GGally: ggplot extensions (pairs plots, ggpairs, ...)
    "ggpubr",          # ggpubr: ready-made publication-ready ggplot wrappers
    "ggrepel",         # ggrepel: non-overlapping text/label geoms for ggplot
    "ggforce",         # ggforce: extra ggplot geoms/facets (zoom, marks, ...)
    "ggthemes",        # ggthemes: additional ggplot themes and scales
    "ggnewscale",      # ggnewscale: multiple independent colour/fill scales per ggplot
    "viridis",         # viridis: perceptually-uniform colour scales
    "plotly",          # plotly: interactive HTML plots (ggplotly)
    "scatterplot3d",   # scatterplot3d: base-graphics 3D scatter plots
    "plot3D",          # plot3D: base-graphics 3D surfaces/scatter
    "tikzDevice",      # tikzDevice: render R graphics to TikZ for LaTeX slides
    "gridGraphics",    # gridGraphics: convert base graphics to grid objects (grab plots)
    "png",             # png: read/write PNG bitmaps (embedding images in slides)
    # --- general stuff
    "reshape2",        # reshape2: melt/cast reshaping (legacy but used across slides)
    "plyr",            # plyr: split-apply-combine (legacy; some slides still use it)
    "microbenchmark",  # microbenchmark: precise timing of short code snippets
    "reticulate",      # reticulate: run Python from R (Python-in-Rmd slide chunks)
    # --- ml packages
    "mlbench",         # mlbench: benchmark ML datasets (used pervasively in examples)
    "ranger",          # ranger: fast random forests
    "kernlab",         # kernlab: kernel methods incl. SVMs (ksvm)
    "e1071",           # e1071: SVMs, naive Bayes, and misc stats utilities
    "kknn",            # kknn: weighted k-nearest-neighbour learner
    "party",           # party: conditional-inference trees/forests
    "partykit",        # partykit: toolkit for recursive partitioning / tree plots
    "DiceKriging",     # DiceKriging: Gaussian-process/kriging models (MBO demos)
    "OpenML",          # OpenML: fetch tasks/datasets from openml.org (old-stack API)
    # --- stats
    "mvtnorm",         # mvtnorm: multivariate normal/t distributions
    "kdensity"         # kdensity: flexible kernel density estimation
)
# dependencies = NA -> hard deps only (Depends/Imports/LinkingTo), no Suggests.
# See the repository-policy note above for why Suggests are excluded.
pak::pak(pkgs, dependencies = NA, ask = FALSE)
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) {
    stop("pak::pak() failed for: ", paste(missing, collapse = ", "), call. = FALSE)
}

# ── Packages NOT on CRAN/PPM — documented exception to the PPM-only policy ──────
# Two packages the i2ml lecture uses are not on CRAN/PPM, so they can't come from the
# date-pinned snapshot above. They install here, in a separate step, and therefore
# float OUTSIDE the date pin. They come from DIFFERENT non-PPM sources AND via
# DIFFERENT installers (see the per-package notes below for why):
#   - mlr3extralearners — from the mlr-org r-universe, installed via pak.
#   - vistool           — NOT on any r-universe (slds-lmu/mlr-org/... all 404); only
#                         the GitHub repo exists, so it is built from GitHub source —
#                         installed via REMOTES (not pak), to dodge a pak bug on the
#                         GitHub-zip extraction path; see the vistool note below.
# PPM is kept in `repos` so both packages' hard deps resolve from the pinned snapshot;
# dependencies = NA keeps it to hard deps only.
#
# SYSTEM DEPS: vistool imports magick and webshot2 — both satisfied by the Dockerfile:
#   - magick links libMagick++ at load time -> libmagick++-dev.
#   - webshot2/chromote launch a headless browser to rasterize htmlwidgets/plotly ->
#     chromium (from the xtradeb PPA, multi-arch), with CHROMOTE_CHROME pointing at it.
options(
    repos = c(
        mlrorg = "https://mlr-org.r-universe.dev",
        PPM    = "https://packagemanager.posit.co/cran/__linux__/noble/2026-06-21"
    )
)
# Re-assert the CA repair right before the only pak solve that needs it (the
# non-PPM r-universe query), in case anything above rewrote pak's cert file.
repair_pak_ca()
# mlr3extralearners: from the mlr-org r-universe, via pak. It arrives as an
# r-universe tar source, which pak extracts on the tar path — NOT the GitHub-zip
# path that is broken below — so pak handles it fine.
pak::pak("mlr3extralearners", dependencies = NA, ask = FALSE)

# vistool: from GitHub, installed with REMOTES — deliberately NOT pak. WHY:
# pak extracts GitHub zipballs via zip::unzip_process(), which loads R6 from pak's
# PRIVATE bundled library (pak/library/R6). In this image that private R6's
# lazy-load DB is corrupt ("...pak/library/R6/R/R6.rdb is corrupt"), so pak fails
# DETERMINISTICALLY (both arches) the moment it packages vistool — the only
# GitHub-zip package in the set. We do NOT try to repair pak's private library
# (its deps are version-pinned to pak; overwriting them risks breaking pak). Instead
# we route vistool around pak: remotes uses base R's download + unzip + R CMD
# INSTALL, never touching pak's private library. vistool's hard deps are already
# satisfied by the main `pkgs` set plus mlr3extralearners above; `repos` (set
# above: r-universe + PPM) resolves any remainder. dependencies = NA = hard deps
# only, matching the policy used everywhere else here.
if (!requireNamespace("remotes", quietly = TRUE)) {
    install.packages("remotes")  # normally present via devtools; be defensive
}
remotes::install_github("slds-lmu/vistool", upgrade = "never", dependencies = NA)

# Post-check by installed package NAME (not the install spec).
extra_names <- c("mlr3extralearners", "vistool")
missing_extra <- setdiff(extra_names, rownames(installed.packages()))
if (length(missing_extra)) {
    stop("pak::pak() failed for non-PPM extras: ",
         paste(missing_extra, collapse = ", "), call. = FALSE)
}
