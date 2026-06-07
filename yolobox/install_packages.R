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
# We deliberately do NOT add r-universe (dev mlr3) or a source-only fallback like
# cloud.r-project.org: r-universe has no date pin and would float the build out of
# reproducibility, and a single date-pinned binary repo means any "package missing
# on Linux noble" condition surfaces as a hard pak error rather than a slow
# source-compile attempt that may also fail.
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
# Make PPM the SOLE repo by REPLACING the repos option outright, rather than
# pak::repo_add() which only appends PPM and leaves the default CRAN entry in
# place — that residual entry could let a package missing from the PPM snapshot
# fall back to a CRAN source compile, the exact behavior the policy above forbids.
# (pak has no repo_set/repo_rm; setting options(repos=) is the supported way, and
# is the canonical Posit/rocker pattern for the __linux__ binary URL.) pak reads
# getOption("repos"), so this single PPM entry is the only repo it resolves against.
options(
    repos = c(
        PPM = "https://packagemanager.posit.co/cran/__linux__/noble/2026-05-31"
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
    "mlr3oml"          # mlr3oml: OpenML integration (fetch tasks/datasets from openml.org)
)
# dependencies = NA -> hard deps only (Depends/Imports/LinkingTo), no Suggests.
# See the repository-policy note above for why Suggests are excluded.
pak::pak(pkgs, dependencies = NA, ask = FALSE)
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) {
    stop("pak::pak() failed for: ", paste(missing, collapse = ", "), call. = FALSE)
}
