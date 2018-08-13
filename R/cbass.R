#' Compute CBASS solution path
#'
#' \code{CBASS} returns a fast approximation to the Convex BiClustering
#' solution path along with visualizations such as dendrograms and
#' heatmaps. Visualizations may be static, interactive, or both.
#'
#' \code{CBASS} solves the Convex Biclustering problem via
#' Algorithmic Regularization Paths. A seqeunce of biclustering
#' solutions is returned along with several visualizations.
#'
#' @param X A n.obs by p.var matrix with rows the observations and columns the variables
#' @param verbose either 0,1,or 2. Higher numbers indicate more verbosity while
#' computing.
#' @param interactive A logical. Should an interactive heatmap be returned?
#' @param static A logical. Should observation and variable dendrograms
#' be returned?
#' @param control a list of CBASS control arguements; see \code{cbass.control}
#' @param ... additional arguments passed to \code{cbass.control}
#' @return X the original data matrix
#' @return cbass.cluster.path.obs the CBASS observation solution path
#' @return cbass.cluster.path.var the CBASS variable solution path
#' @return cbass.dend.obs if static==TRUE, a dendrogam representation of the
#' observation clustering solution path
#' @return cbass.dend.var if static==TRUE, a dendrogam representation of the
#' variable clustering solution path
#' @return phi.obs A positive numner used for scaling in observation RBF kernel
#' @return phi.var A positive numner used for scaling in variable RBF kernel
#' @return k.obs an integer >= 1. The number of neighbors used to create sparse
#' observation weights
#' @return k.var an integer >= 1. The number of neighbors used to create sparse
#' variable weights
#' @return burn.in an integer. The number of initial iterations at a fixed
#' value of (small) lambda_k
#' @return alg.type Which CARP algorithm to perform. Choices are 'cbassviz',
#' 'cbass','cbassl1', and 'cbassvizl1'
#' @return interactive A logical. Should an interactive heatmap be returned?
#' @return static A logical. Should observation and variable dendrograms
#' be returned?
#' @return obs.labels a vector of length n.obs containing observations (row) labels
#' @return var.labels a vector of length p.var containing variable (column) labels
#' @return X.center.global a logical. If TRUE, the global mean of X is removed.
#' @importFrom stats var
#' @export
#' @examples
#' \dontrun{
#' library(clustRviz)
#' data("presidential_speech")
#' Xdat <- presidential_speech
#' CBASS(
#' X=Xdat
#' ) -> cbass.fit
#' }
CBASS <- function(X,
                  verbose = 1,
                  interactive = TRUE,
                  static = TRUE,
                  control = NULL,
                  ...) {

  if (!is.matrix(X)) {
    warning(sQuote("X"), " should be a matrix, not a " , class(X)[1],
            ". Converting with as.matrix().")
    X <- as.matrix(X)
  }

  if (!is.numeric(X)) {
    stop(sQuote("X"), " must be numeric.")
  }

  n.obs <- NROW(X)
  p.var <- NCOL(X)

  if (anyNA(X)) {
    stop(sQuote("CBASS"), " cannot handle missing data.")
  }

  if (!all(is.finite(X))) {
    stop("All elements of ", sQuote("X"), " must be finite.")
  }

  if (is.logical(verbose)) {
    verbose.basic <- TRUE
    verbose.deep <- FALSE
  } else if (verbose == 1) {
    verbose.basic <- TRUE
    verbose.deep <- FALSE
  } else if (verbose == 2) {
    verbose.basic <- TRUE
    verbose.deep <- TRUE
  } else {
    verbose.basic <- FALSE
    verbose.deep <- FALSE
  }

  extra.args <- list(...)
  if (length(extra.args)) {
    control.args <- names(formals(cbass.control))
    indx <- match(names(extra.args), control.args, nomatch = 0L)
    if (any(indx == 0L)) {
      stop(gettextf("Argument %s not matched", names(extra.args)[indx == 0L]), domain = NA)
    }
  }
  internal.control <- cbass.control(...)
  if (!is.null(control)) {
    internal.control[names(control)] <- control
  }
  obs.labels <- internal.control$obs.labels
  var.labels <- internal.control$var.labels
  X.center.global <- internal.control$X.center.global
  k.obs <- internal.control$k.obs
  k.var <- internal.control$k.var
  phi <- internal.control$phi
  rho <- internal.control$rho
  weights.obs <- internal.control$weights.obs
  weights.var <- internal.control$weights.var
  obs.weight.dist <- internal.control$obs.weight.dist
  var.weight.dist <- internal.control$var.weight.dist
  obs.weight.dist.p <- internal.control$obs.weight.dist.p
  var.weight.dist.p <- internal.control$var.weight.dist.p
  ncores <- internal.control$ncores
  max.iter <- internal.control$max.iter
  burn.in <- internal.control$burn.in
  alg.type <- internal.control$alg.type
  t <- internal.control$t
  npcs <- internal.control$npcs



  # get labels
  if (is.null(obs.labels)) {
    if (!is.null(rownames(X))) {
      n.labels <- rownames(X)
    } else {
      n.labels <- 1:NROW(X)
    }
  } else {
    if (length(obs.labels) == n.obs) {
      n.labels <- obs.labels
    } else {
      stop("obs.labels should be length NROW(X)")
    }
  }
  if (is.null(var.labels)) {
    if (!is.null(colnames(X))) {
      p.labels <- colnames(X)
    } else {
      p.labels <- 1:NCOL(X)
    }
  } else {
    if (length(var.labels) == p.var) {
      p.labels <- var.labels
    } else {
      stop("var.labels should be length NCOL(X)")
    }
  }
  if (!is.null(phi)) {
    if (phi <= 0) {
      stop("phi should be positive.")
    }
  }


  # center and scale
  colnames(X) <- var.labels
  rownames(X) <- obs.labels
  X.orig <- X
  if (X.center.global) {
    X <- X - mean(X)
    X <- t(X)
  } else {
    X <- t(X)
  }

  if (!is.null(weights.var)) {
    if (length(weights.var) == choose(p.var, 2)) {
      weights.row <- weights.var
    } else {
      stop("weights.var should be length choose(NCOL(X),2)")
    }
  } else {
    if (is.null(phi)) {
      phi.vec <- 10^(-10:10)
      sapply(phi.vec, function(phi) {
        stats::var(DenseWeights(X = X, phi = phi, method = var.weight.dist, p = var.weight.dist.p))
      }) %>%
        which.max() %>%
        phi.vec[.] -> phi
    }
    phi.row <- phi / n.obs
    weights.row <- DenseWeights(X = X, phi = phi.row, method = var.weight.dist, p = var.weight.dist.p)
    if (is.null(k.var)) {
      k.row <- MinKNN(X = X, dense.weights = weights.row)
    } else {
      k.row <- k.var
    }
    weights.row <- SparseWeights(X = X, dense.weights = weights.row, k = k.row)
  }
  weights.row <- weights.row / sum(weights.row)
  weights.row <- weights.row / sqrt(n.obs)

  PreCompList.row <- suppressMessages(
    ConvexClusteringPreCompute(
      X = t(X),
      weights = weights.row,
      ncores = ncores, rho = rho
    )
  )
  cardE.row <- NROW(PreCompList.row$E)

  if (!is.null(weights.obs)) {
    if (length(weights.obs) == choose(n.obs, 2)) {
      weights.cols <- weights.obs
    } else {
      stop("weights.obs should have length choose(NROW(X),2)")
    }
  } else {
    phi.col <- phi / p.var
    weights.col <- DenseWeights(X = t(X), phi = phi.col, method = obs.weight.dist, p = obs.weight.dist.p)
    if (is.null(k.obs)) {
      k.col <- MinKNN(X = t(X), dense.weights = weights.col)
    } else {
      k.col <- k.obs
    }
    weights.col <- SparseWeights(X = t(X), dense.weights = weights.col, k = k.col)
  }
  weights.col <- weights.col / sum(weights.col)
  weights.col <- weights.col / sqrt(p.var)

  PreCompList.col <- suppressMessages(
    ConvexClusteringPreCompute(
      X = X,
      weights = weights.col,
      ncores = ncores, rho = rho
    )
  )
  cardE.col <- NROW(PreCompList.col$E)



  if (verbose.basic) message("Computing CBASS Path\n")
  switch(
    alg.type,
    cbassviz = {
      BICARPL2_VIS(
        x = X[TRUE],
        n = as.integer(n.obs),
        p = as.integer(p.var),
        lambda_init = 1e-6,
        weights_row = weights.row[weights.row != 0],
        weights_col = weights.col[weights.col != 0],
        uinit_row = as.matrix(PreCompList.row$uinit),
        uinit_col = as.matrix(PreCompList.col$uinit),
        vinit_row = as.matrix(PreCompList.row$vinit),
        vinit_col = as.matrix(PreCompList.col$vinit),
        premat_row = PreCompList.row$PreMat,
        premat_col = PreCompList.col$PreMat,
        IndMat_row = PreCompList.row$ind.mat,
        IndMat_col = PreCompList.col$ind.mat,
        EOneIndMat_row = PreCompList.row$E1.ind.mat,
        EOneIndMat_col = PreCompList.col$E1.ind.mat,
        ETwoIndMat_row = PreCompList.row$E2.ind.mat,
        ETwoIndMat_col = PreCompList.col$E2.ind.mat,
        rho = rho,
        max_iter = as.integer(max.iter),
        burn_in = burn.in,
        verbose = verbose.deep,
        verbose_inner = verbose.deep,
        try_tol = 1e-3,
        ti = 10,
        t_switch = 1.01
      ) -> bicarp.sol.path
    },
    cbassvizl1 = {
      BICARPL1_VIS(
        x = X[TRUE],
        n = as.integer(n.obs),
        p = as.integer(p.var),
        lambda_init = 1e-6,
        weights_row = weights.row[weights.row != 0],
        weights_col = weights.col[weights.col != 0],
        uinit_row = as.matrix(PreCompList.row$uinit),
        uinit_col = as.matrix(PreCompList.col$uinit),
        vinit_row = as.matrix(PreCompList.row$vinit),
        vinit_col = as.matrix(PreCompList.col$vinit),
        premat_row = PreCompList.row$PreMat,
        premat_col = PreCompList.col$PreMat,
        IndMat_row = PreCompList.row$ind.mat,
        IndMat_col = PreCompList.col$ind.mat,
        EOneIndMat_row = PreCompList.row$E1.ind.mat,
        EOneIndMat_col = PreCompList.col$E1.ind.mat,
        ETwoIndMat_row = PreCompList.row$E2.ind.mat,
        ETwoIndMat_col = PreCompList.col$E2.ind.mat,
        rho = rho,
        max_iter = as.integer(max.iter),
        burn_in = burn.in,
        verbose = verbose.deep,
        verbose_inner = verbose.deep,
        try_tol = 1e-3,
        ti = 10,
        t_switch = 1.01
      ) -> bicarp.sol.path
    },
    cbass = {
      BICARPL2_NF_FRAC(
        x = X[TRUE],
        n = as.integer(n.obs),
        p = as.integer(p.var),
        lambda_init = 1e-6,
        t = t,
        weights_row = weights.row[weights.row != 0],
        weights_col = weights.col[weights.col != 0],
        uinit_row = as.matrix(PreCompList.row$uinit),
        uinit_col = as.matrix(PreCompList.col$uinit),
        vinit_row = as.matrix(PreCompList.row$vinit),
        vinit_col = as.matrix(PreCompList.col$vinit),
        premat_row = PreCompList.row$PreMat,
        premat_col = PreCompList.col$PreMat,
        IndMat_row = PreCompList.row$ind.mat,
        IndMat_col = PreCompList.col$ind.mat,
        EOneIndMat_row = PreCompList.row$E1.ind.mat,
        EOneIndMat_col = PreCompList.col$E1.ind.mat,
        ETwoIndMat_row = PreCompList.row$E2.ind.mat,
        ETwoIndMat_col = PreCompList.col$E2.ind.mat,
        rho = rho,
        max_iter = as.integer(max.iter),
        burn_in = burn.in,
        verbose = verbose.deep,
        keep = 10
      ) -> bicarp.sol.path
    },
    cbassl1 = {
      BICARPL1_NF_FRAC(
        x = X[TRUE],
        n = as.integer(n.obs),
        p = as.integer(p.var),
        lambda_init = 1e-6,
        t = t,
        weights_row = weights.row[weights.row != 0],
        weights_col = weights.col[weights.col != 0],
        uinit_row = as.matrix(PreCompList.row$uinit),
        uinit_col = as.matrix(PreCompList.col$uinit),
        vinit_row = as.matrix(PreCompList.row$vinit),
        vinit_col = as.matrix(PreCompList.col$vinit),
        premat_row = PreCompList.row$PreMat,
        premat_col = PreCompList.col$PreMat,
        IndMat_row = PreCompList.row$ind.mat,
        IndMat_col = PreCompList.col$ind.mat,
        EOneIndMat_row = PreCompList.row$E1.ind.mat,
        EOneIndMat_col = PreCompList.col$E1.ind.mat,
        ETwoIndMat_row = PreCompList.row$E2.ind.mat,
        ETwoIndMat_col = PreCompList.col$E2.ind.mat,
        rho = rho,
        max_iter = as.integer(max.iter),
        burn_in = burn.in,
        verbose = verbose.deep,
        keep = 10
      ) -> bicarp.sol.path
    }
  )

  if (verbose.basic) message("Post-processing\n")
  ISP(
    sp.path = bicarp.sol.path$v.row.zero.inds %>% t(),
    v.path = bicarp.sol.path$v.row.path,
    u.path = bicarp.sol.path$u.path,
    lambda.path = bicarp.sol.path$lambda.path,
    cardE = sum(weights.row != 0)
  ) -> bicarp.cluster.path.row
  bicarp.cluster.path.row$sp.path.inter %>% duplicated(fromLast = FALSE) -> sp.path.dups.row
  adj.path.row <- CreateAdjacencyPath(PreCompList.row$E, sp.path = bicarp.cluster.path.row$sp.path.inter, p.var)
  clust.graph.path.row <- CreateClusterGraphPath(adj.path.row)
  clust.path.row <- GetClustersPath(clust.graph.path.row)
  clust.path.dups.row <- duplicated(clust.path.row, fromLast = FALSE)

  bicarp.cluster.path.row[["sp.path.dups"]] <- sp.path.dups.row
  bicarp.cluster.path.row[["adj.path"]] <- adj.path.row
  bicarp.cluster.path.row[["clust.graph.path"]] <- clust.graph.path.row
  bicarp.cluster.path.row[["clust.path"]] <- clust.path.row
  bicarp.cluster.path.row[["clust.path.dups"]] <- clust.path.dups.row

  bicarp.dend.row <- CreateDendrogram(bicarp.cluster.path.row, p.labels)



  ISP(
    sp.path = bicarp.sol.path$v.col.zero.inds %>% t(),
    v.path = bicarp.sol.path$v.col.path,
    u.path = bicarp.sol.path$u.path,
    lambda.path = bicarp.sol.path$lambda.path,
    cardE = sum(weights.col != 0)
  ) -> bicarp.cluster.path.col
  bicarp.cluster.path.col$sp.path.inter %>% duplicated(fromLast = FALSE) -> sp.path.dups.col
  adj.path.col <- CreateAdjacencyPath(PreCompList.col$E, sp.path = bicarp.cluster.path.col$sp.path.inter, n.obs)
  clust.graph.path.col <- CreateClusterGraphPath(adj.path.col)
  clust.path.col <- GetClustersPath(clust.graph.path.col)
  clust.path.dups.col <- duplicated(clust.path.col, fromLast = FALSE)

  bicarp.cluster.path.col[["sp.path.dups"]] <- sp.path.dups.col
  bicarp.cluster.path.col[["adj.path"]] <- adj.path.col
  bicarp.cluster.path.col[["clust.graph.path"]] <- clust.graph.path.col
  bicarp.cluster.path.col[["clust.path"]] <- clust.path.col
  bicarp.cluster.path.col[["clust.path.dups"]] <- clust.path.dups.col

  bicarp.dend.col <- CreateDendrogram(bicarp.cluster.path.col, n.labels)
  cbass.fit <- list(
    X = X.orig,
    cbass.sol.path = bicarp.sol.path,
    cbass.cluster.path.obs = bicarp.cluster.path.col,
    cbass.cluster.path.var = bicarp.cluster.path.row,
    cbass.dend.var = bicarp.dend.row,
    cbass.dend.obs = bicarp.dend.col,
    n.obs = n.obs,
    p.var = p.var,
    phi.var = phi.row,
    phi.obs = phi.col,
    k.obs = k.col,
    k.var = k.row,
    burn.in = burn.in,
    alg.type = alg.type,
    t = t,
    X.center.global = X.center.global,
    static = static,
    interactive = interactive,
    obs.labels = n.labels,
    var.labels = p.labels
  )
  class(cbass.fit) <- "CBASS"
  return(cbass.fit)
}

#' Control for CBASS fits
#'
#' Parameters for various CBASS fitting options
#'
#'
#' @param obs.labels a vector of length n.obs containing observations (row) labels
#' @param var.labels a vector of length p.var containing variable (column) labels
#' @param X.center.global a logical. If TRUE, the global mean of X is removed.
#' @param rho A positive number for augmented lagrangian. Not advisable to change.
#' @param phi A positive numner used for scaling in RBF kernel
#' @param weights.obs A vector of positive number of length choose(n.obs,2).
#' Determines observation pair fusions weight.
#' @param weights.var A vector of positive number of length choose(p.var,2).
#' Determines variable pair fusions weight.
#' @param obs.weight.dist a string indicating the distance metric used to calculate
#' observation weights
#' @param obs.weight.dist.p The power of the Minkowski distance, if used for
#' observation weights.
#' @param var.weight.dist a string indicating the distance metric used to calculate
#' variable weights
#' @param var.weight.dist.p The power of the Minkowski distance, if used for
#' variable weights.
#' @param k.obs an integer >= 1. The number of neighbors used to create sparse
#' observation weights
#' @param k.var an integer >= 1. The number of neighbors used to create sparse
#' variable weights
#' @param ncores an integer >= 1. The number of cores to use.
#' @param max.iter an integer. The maximum number of CARP iterations.
#' @param burn.in an integer. The number of initial iterations at a fixed
#' value of (small) lambda_k
#' @param alg.type Which CARP algorithm to perform. Choices are 'cbassviz'
#' and 'cbass';
#' @param t a number greater than 1. The size of the multiplicitive
#' regularization parameter update. Typical values are: 1.1, 1.05, 1.01, 1.005.
#' Not used CBASS-VIZ algorithms.
#' @param npcs A integer >= 2. The number of principal components to compute
#' for path visualization.
#' @param ... unused additional arguements
#' @return a list of CBASS parameters
#' @export
cbass.control <- function(
                          obs.labels = NULL,
                          var.labels = NULL,
                          X.center.global = TRUE,
                          rho = 1,
                          phi = NULL,
                          weights.obs = NULL,
                          weights.var = NULL,
                          obs.weight.dist = "euclidean",
                          obs.weight.dist.p = 2,
                          var.weight.dist = "euclidean",
                          var.weight.dist.p = 2,
                          k.obs = NULL,
                          k.var = NULL,
                          t = 1.01,
                          ncores = as.integer(1),
                          max.iter = as.integer(1e6),
                          burn.in = as.integer(50),
                          alg.type = "cbassviz",
                          npcs = as.integer(4)) {
  if (!is.logical(X.center.global)) {
    stop("X.global should be either TRUE or FALSE")
  }
  if (rho < 0) {
    stop("rho should be non-negative")
  }
  if (!(obs.weight.dist %in% c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"))) {
    stop("unrecognized obs.weight.dist argument; see method arguement of stats::dist for options.")
  }
  if (obs.weight.dist.p <= 0) {
    stop("obs.weight.dist.p should be > 0; see p argument of stats::dist for details.")
  }
  if (!(var.weight.dist %in% c("euclidean", "maximum", "manhattan", "canberra", "binary", "minkowski"))) {
    stop("unrecognized var.weight.dist argument; see method arguement of stats::dist for options.")
  }
  if (var.weight.dist.p <= 0) {
    stop("var.weight.dist.p should be > 0; see p argument of stats::dist for details.")
  }
  if (!is.null(k.obs)) {
    if (!is.integer(k.obs) | k.obs >= 0) {
      stop("k should be a positive integer.")
    }
  }
  if (!is.null(k.var)) {
    if (!is.integer(k.var) | k.var >= 0) {
      stop("k should be a positive integer.")
    }
  }
  if (!is.integer(ncores) | ncores <= 0) {
    stop("ncores should be a positive integer.")
  }
  if (!is.integer(max.iter) | max.iter <= 0) {
    stop("max.iter should be a positive integer.")
  }
  if (!is.integer(burn.in) | burn.in <= 0 | burn.in >= max.iter) {
    stop("burn.in should be a positive integer greater than max.iter.")
  }
  if (!(alg.type %in% c("cbassviz", "cbass", "cbassl1", "cbassvizl1"))) {
    stop("unrecognized alg.type. see help for details.")
  }
  if (t <= 1) {
    stop("t should be greater than 1.")
  }
  if (!is.integer(npcs) | npcs < 2) {
    stop("npcs should be an integer greater than or equal to 2.")
  }
  list(
    obs.labels = obs.labels,
    var.labels = var.labels,
    X.center.global = X.center.global,
    rho = rho,
    phi = phi,
    weights.obs = weights.obs,
    weights.var = weights.var,
    obs.weight.dist = obs.weight.dist,
    obs.weight.dist.p = obs.weight.dist.p,
    var.weight.dist = var.weight.dist,
    var.weight.dist.p = var.weight.dist.p,
    k.obs = k.obs,
    k.var = k.var,
    t = t,
    ncores = ncores,
    max.iter = max.iter,
    burn.in = burn.in,
    alg.type = alg.type
  )
}


#' Print \code{CARP} Results
#'
#' Prints a brief descripton of a fitted \code{CARP} object.
#'
#' Reports number of observations and variables of dataset, any preprocessing
#' done by the \code{\link{CARP}} function, regularization weight information,
#' the of \code{CARP} algorithm performed, and the visualizations returned.
#'
#' @param x an object of class \code{CARP} as returned by \code{\link{CARP}}
#' @param ... Additional unused arguments
#' @export
#' @examples
#' carp.fit <- CARP(presidential_speech[1:10,1:4])
#' print(carp.fit)

#' Print \code{CBASS} Results
#'
#' Prints a brief descripton of a fitted \code{CBASS} object.
#'
#' Reports number of observations and variables of dataset, any preprocessing
#' done by the \code{\link{CBASS}} function, regularization weight information,
#' the variant of \code{CBASS} used, and the visualizations returned.
#' @param x an object of class \code{CBASS} as returned by \code{\link{CBASS}}
#' @param ... Additional unused arguments
#' @export
#' @examples
#' cbass_fit <- CBASS(X=presidential_speech[1:10,1:4])
#' print(cbass_fit)
print.CBASS <- function(x, ...) {
  alg_string <- switch(x$alg.type,
                       carp      = paste0("CBASS (t = ", round(x$t, 3), ")"),
                       carpl1    = paste0("CBASS(t = ", round(x$t, 3), ") [L1]"),
                       carlviz   = "CBASS-VIZ",
                       carpvizl1 = "CBASS-VIZ [L1]")

  cat("CBASS Fit Summary\n")
  cat("====================\n\n")
  cat("Algorithm: ", alg.string, "\n\n")

  cat("Available Visualizations:\n")
  cat(" - Static Dendrogram:   ", x$static, "\n")
  cat(" - Static Heatmap:      ", x$static, "\n")
  cat(" - Interactive Heatmap: ", x$interactive, "\n\n")

  cat("Number of Observations: ", x$n.obs, "\n")
  cat("Number of Variables:    ", x$p.var, "\n\n")

  cat("Pre-processing options:\n")
  cat(" - Global centering: ", x$X.center.global, "\n\n")

  cat("Observation RBF Kernel Weights:\n") # TODO: Add descriptions of what these parameters represent
  cat(" - phi = ", round(x$phi.obs, 3), "\n")
  cat(" - K   = ", x$k.obs, "\n\n")

  cat("Variable RBF Kernel Weights:\n") # TODO: Add descriptions of what these parameters represent
  cat(" - phi = ", round(x$phi.var, 3), "\n")
  cat(" - K   = ", x$k.var, "\n\n")

  cat("Raw Data:\n")
  print(x$X[1:min(5, x$n.obs), 1:min(5, x$p.var)])

  invisible(x)
}