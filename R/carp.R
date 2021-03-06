#' Compute \code{CARP} (Convex Clustering) Solution Path
#'
#' \code{CARP} returns a fast approximation to the Convex Clustering
#' solution path along with visualizations such as dendrograms and
#' cluster paths. \code{CARP} solves the Convex Clustering problem via
#' Algorithmic Regularization Paths. A seqeunce of clustering
#' solutions is returned along with several visualizations.
#'
#' @param X The data matrix (\eqn{X \in R^{n \times p}}{X}): rows correspond to
#'          the observations (to be clustered) and columns to the variables (which
#'          will not be clustered).
#' @param verbose Any of the values \code{0}, \code{1}, or \code{2}. Higher values
#'                correspond to more verbose output while running.
#' @param control A list containing advanced parameters for the \code{CARP} algorithm,
#'                typically created by \code{\link{carp.control}}.
#' @param ... Additional arguments used to control the behavior of \code{CARP}; see
#'            \code{\link{carp.control}} for details.
#' @return An object of class \code{CARP} containing the following elements (among others):
#'         \itemize{
#'         \item \code{X}: the original data matrix
#'         \item \code{n.obs}: the number of observations (rows of \code{X})
#'         \item \code{p.var}: the number of variables (columns of \code{X})
#'         \item \code{alg.type}: the \code{CARP} variant used
#'         \item \code{X.center}: a logical indicating whether \code{X} was centered
#'                                column-wise before clustering
#'         \item \code{X.scale}: a logical indicating whether \code{X} was scaled
#'                               column-wise before centering
#'         \item \code{burn.in}: an integer indicating the number of "burn-in"
#'                               iterations performed
#'         \item \code{k}: the number of neighbors used to create sparse clustering weights
#'         \item \code{phi}: the scale factor of the RBF kernel used to calculate
#'                           clustering weights
#'         \item \code{carp.dend}: a dendrogram (object of class
#'                                 \code{\link[stats]{hclust}}) containing
#'                                 the clustering solution path
#'         \item \code{carp.cluster.path.vis}: The \code{CARP} solution path
#'         }
#' @importFrom utils data
#' @importFrom dplyr %>% mutate group_by ungroup as_tibble n_distinct
#' @importFrom stats var
#' @importFrom utils modifyList
#' @export
#' @examples
#' carp_fit <- CARP(presidential_speech[1:10,1:4])
#' print(carp_fit)
#' plot(carp_fit)
CARP <- function(X,
                 verbose = 1L,
                 ...,
                 control = NULL) {

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
    stop(sQuote("CARP"), " cannot handle missing data.")
  }

  if (!all(is.finite(X))) {
    stop("All elements of ", sQuote("X"), " must be finite.")
  }

  Iter <- Cluster <- Lambda <- NULL
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

  internal.control <- carp.control(...)
  if (!is.null(control)) {
    internal.control <- modifyList(internal.control, control)
  }

  obs.labels <- internal.control$obs.labels
  var.labels <- internal.control$var.labels
  X.center <- internal.control$X.center
  X.scale <- internal.control$X.scale
  k <- internal.control$k
  phi <- internal.control$phi
  rho <- internal.control$rho
  weights <- internal.control$weights
  weight.dist <- internal.control$weight.dist
  weight.dist.p <- internal.control$weight.dist.p
  max.iter <- internal.control$max.iter
  burn.in <- internal.control$burn.in
  alg.type <- internal.control$alg.type
  t <- internal.control$t
  npcs <- internal.control$npcs
  dendrogram.scale <- internal.control$dendrogram.scale

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
      stop("obs.labels should hve length NROW(X)")
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
      stop("var.labels should be have length NCOL(X)")
    }
  }

  if (is.null(npcs)) {
    npcs <- min(4, p.var)
    npcs <- as.integer(npcs)
  } else {
    npcs <- as.integer(npcs)
    if (!is.integer(npcs) | npcs < 2) {
      stop("npcs should be an integer greater than or equal to 2.")
    }
    if (npcs > p.var) {
      stop("npcs should be less than or equal to NCOL(X)")
    }
  }
  if (!is.null(phi)) {
    if (phi <= 0) {
      stop("phi should be positive.")
    }
  }

  if (length(unique(p.labels) != length(p.labels))) {
    colnames(X) <- make.names(p.labels, unique = TRUE)
  } else {
    colnames(X) <- p.labels
  }
  if (length(unique(n.labels)) != length(n.labels)) {
    rownames(X) <- make.names(n.labels, unique = TRUE)
  } else {
    rownames(X) <- n.labels
  }

  # center and scale
  X.orig <- X
  if (X.center | X.scale) {
    X %>%
      scale(center = X.center, scale = X.scale) %>%
      t() -> X
  } else {
    X <- t(X)
  }

  # get weights
  if (is.null(weights)) {
    if (is.null(phi)) {
      phi.vec <- 10^(-10:10)
      sapply(phi.vec, function(phi) {
        stats::var(DenseWeights(X = t(X), phi = phi, method = weight.dist, p = weight.dist.p))
      }) %>%
        which.max() %>%
        phi.vec[.] -> phi
    }
    weights <- DenseWeights(t(X), phi = phi, method = weight.dist, p = weight.dist.p)
    if (is.null(k)) {
      k <- MinKNN(t(X), weights)
    }
    weights <- SparseWeights(X = t(X), dense.weights = weights, k = k)
  } else {
    if (length(weights) != choose(n.obs, 2)) {
      stop("Incorrect weight length")
    }
  }


  if (verbose.basic) message("Pre-computing weight-based edge sets")
  PreCompList <- suppressMessages(ConvexClusteringPreCompute(
    X = X,
    weights = weights,
    rho = rho
  ))
  cardE <- NROW(PreCompList$E)

  if (verbose.basic) message("Computing CARP Path")

  if (alg.type %in% c("carpvizl1", "carpviz")) {
      carp.sol.path <- CARP_VIZcpp(x = X[TRUE],
                                   n = as.integer(n.obs),
                                   p = as.integer(p.var),
                                   lambda_init = 1e-8,
                                   weights = weights[weights != 0],
                                   uinit = as.matrix(PreCompList$uinit),
                                   vinit = as.matrix(PreCompList$vinit),
                                   premat = PreCompList$PreMat,
                                   IndMat = PreCompList$ind.mat,
                                   EOneIndMat = PreCompList$E1.ind.mat,
                                   ETwoIndMat = PreCompList$E2.ind.mat,
                                   rho = rho,
                                   max_iter = as.integer(max.iter),
                                   burn_in = as.integer(burn.in),
                                   verbose = verbose.deep,
                                   ti = 10,
                                   t_switch = 1.01,
                                   keep = 1,
                                   l1 = (alg.type == "carpvizl1"))
  } else {
      carp.sol.path <- CARPcpp(x = X[TRUE],
                               n = as.integer(n.obs),
                               p = as.integer(p.var),
                               lambda_init = 1e-8,
                               t = t,
                               weights = weights[weights != 0],
                               uinit = as.matrix(PreCompList$uinit),
                               vinit = as.matrix(PreCompList$vinit),
                               premat = PreCompList$PreMat,
                               IndMat = PreCompList$ind.mat,
                               EOneIndMat = PreCompList$E1.ind.mat,
                               ETwoIndMat = PreCompList$E2.ind.mat,
                               rho = rho,
                               max_iter = as.integer(max.iter),
                               burn_in = as.integer(burn.in),
                               verbose = verbose.deep,
                               keep = 1,
                               l1 = (alg.type == "carpl1"))
  }

  ## FIXME - Convert lambda.path to a single column matrix instead of a vector
  ##         RcppArmadillo returns a arma::vec as a n-by-1 matrix
  ##         RcppEigen returns an Eigen::VectorXd as a n-length vector
  ##         Something downstream cares about the difference, so just change
  ##         the type here for now
  carp.sol.path$lambda.path <- matrix(carp.sol.path$lambda.path, ncol=1)

  if (verbose.basic) message("Post-processing")
  ISP(
    sp.path = carp.sol.path$v.zero.inds %>% t(),
    v.path = carp.sol.path$v.path,
    u.path = carp.sol.path$u.path,
    lambda.path = carp.sol.path$lambda.path,
    cardE = cardE
  ) -> carp.cluster.path

  clust.path <- get_cluster_assignments(PreCompList$E, carp.cluster.path$sp.path.inter, n.obs)
  clust.path.dups <- duplicated(clust.path, fromLast = FALSE)

  carp.cluster.path[["clust.path"]] <- clust.path
  carp.cluster.path[["clust.path.dups"]] <- clust.path.dups

  carp.dend <- CreateDendrogram(carp.cluster.path, n.labels, dendrogram.scale)

  X.pca <- stats::prcomp(t(X), scale. = FALSE, center = FALSE)
  X.pca.rot <- X.pca$rotation[, 1:npcs]

  U_projected <- crossprod(matrix(carp.cluster.path$u.path.inter, nrow = p.var), X.pca.rot)
  colnames(U_projected) <- paste0("PC", 1:npcs)

  carp.cluster.path.vis <- as_tibble(U_projected) %>%
                              mutate(Iter = rep(seq_along(carp.cluster.path$clust.path), each = n.obs),
                                     Obs  = rep(seq_len(n.obs), times = length(carp.cluster.path$clust.path)),
                                     Cluster = as.vector(vapply(carp.cluster.path$clust.path, function(x) x$membership, double(n.obs))),
                                     Lambda = rep(carp.cluster.path$lambda.path.inter, each = n.obs),
                                     ObsLabel = rep(n.labels, times = length(carp.cluster.path$clust.path))) %>%
                              group_by(Iter) %>%
                              mutate(NCluster = n_distinct(Cluster)) %>%
                              ungroup() %>%
                              mutate(LambdaPercent = Lambda / max(Lambda))

  carp.fit <- list(
    X = X.orig,
    carp.dend = carp.dend,
    carp.cluster.path.vis = carp.cluster.path.vis,
    carp.sol.path = carp.sol.path,
    cardE = cardE,
    n.obs = n.obs,
    p.var = p.var,
    phi = phi,
    k = k,
    burn.in = burn.in,
    alg.type = alg.type,
    t = t,
    X.center = X.center,
    X.scale = X.scale
  )

  class(carp.fit) <- "CARP"

  return(carp.fit)
}

#' Control for \code{CARP} fits
#'
#' Set \code{CARP} algorithm parameters
#'
#' This function constructs a list containing additional arguments to control
#' the behavior of the \code{CARP} algorithm. It is typically only used internally
#' by \code{\link{CARP}}, but may be useful to advanced users who wish to
#' construct the \code{control} argument directly.
#'
#' @param obs.labels A character vector of length \eqn{n}: observations (row) labels
#' @param var.labels A character vector of length \eqn{p}: variable (column) labels
#' @param X.center A logical: Should \code{X} be centered columnwise?
#' @param X.scale A logical: Should \code{X} be scaled columnwise?
#' @param rho For advanced users only (not advisable to change): the penalty
#'            parameter used for the augmented Lagrangian.
#' @param weights A vector of positive number of length \code{choose(n,2)}.
#' @param k An positive integer: the number of neighbors used to create sparse weights
#' @param weight.dist A string indicating the distance metric used to calculate weights.
#'                    See \code{\link[stats]{dist}} for details.
#' @param weight.dist.p The exponent used to calculate the Minkowski distance if
#'                      \code{weight.dist = "minkowski"}.
#'                      See \code{\link[stats]{dist}} for details.
#' @param phi A positive real number: the scale factor used in the RBF kernel
#' @param max.iter An integer: the maximum number of CARP iterations.
#' @param burn.in An integer: the number of initial iterations at a fixed
#'                (small) value of \eqn{\lambda}
#' @param alg.type Which \code{CARP} variant to use. Allowed values are \itemize{
#'        \item \code{"carp"} - The standard \code{CARP} algorithm with \eqn{L2} penalty;
#'        \item \code{"carpviz"} - The back-tracking \code{CARP} algorithm with \eqn{L2} penalty;
#'        \item \code{"carpl1"} - The standard \code{CARP} algorithm with \eqn{L1} penalty; and
#'        \item \code{"carpvizl1"} - The back-tracking \code{CARP} algorithm with \eqn{L1} penalty.}
#' @param t A number greater than 1: the size of the multiplicative update to
#'          the cluster fusion regularization parameter (not used by
#'          back-tracking variants). Typically on the scale of \code{1.005} to \code{1.1}.
#' @param npcs An integer >= 2. The number of principal components to compute
#'             for path visualization.
#' @param dendrogram.scale A character string denoting how the scale of dendrogram
#' regularization proportions should be visualized. Choices are \code{'original'}
#' or \code{'log'}; if not provided, a data-driven heuristic choice is used.
#' @param ... Unused arguements. An error will be thrown if any unrecognized
#'            arguments as given.
#' @return A list containing the \code{CARP} algorithm parameters.
#' @export
carp.control <- function(obs.labels = NULL,
                         var.labels = NULL,
                         X.center = TRUE,
                         X.scale = FALSE,
                         phi = NULL,
                         rho = 1,
                         weights = NULL,
                         k = NULL,
                         weight.dist = "euclidean",
                         weight.dist.p = 2,
                         max.iter = 1000000L,
                         burn.in = 50L,
                         alg.type = "carpviz",
                         t = 1.05,
                         npcs = NULL,
                         dendrogram.scale = NULL,
                         ...) {

  dots <- list(...)

  if (length(dots) != 0L) {
    if (!is.null(names(dots))) {
      stop("Unknown argument ", sQuote(names(dots)[1L]), " passed to ", sQuote("CARP."))
    } else {
      stop("Unknown ", sQuote("..."), " arguments passed to ", sQuote("CARP."))
    }
  }

  if (!is.logical(X.center) || is.na(X.center) || (length(X.center) != 1L)) {
    stop(sQuote("X.center"), "must be either ", sQuote("TRUE"), " or ", sQuote("FALSE."))
  }

  if (!is.logical(X.scale) || is.na(X.scale) || (length(X.scale) != 1L)) {
    stop(sQuote("X.scale"), "must be either ", sQuote("TRUE"), " or ", sQuote("FALSE."))
  }

  if ((rho < 0) || is.na(rho) || (length(rho) != 1L)) {
    stop(sQuote("rho"), "must a be non-negative scalar.")
  }

  if (weight.dist %not.in% SUPPORTED_DISTANCES) {
    stop("Unsupported choice of ",
         sQuote("weight.dist;"),
         " see the ", sQuote("method"),
         " argument of ",
         sQuote("stats::dist"),
         " for supported distances.")
  }

  if ((weight.dist.p <= 0) || (length(weight.dist.p) != 1L)) {
    stop(sQuote("weight.dist.p"),
         " must be a positive scalar; see the ", sQuote("p"),
         " argument of ", sQuote("stats::dist"), " for details.")
  }

  if (!is.null(npcs)) {
    if (!is.integer(npcs) || npcs <= 1L) {
      stop(sQuote("npcs"), " must be at least 2.")
    }
  }

  if (!is.null(k)) {
    if (!is.integer(k) || k <= 0) {
      stop("If not NULL, ", sQuote("k"), " must be a positive integer.")
    }
  }

  if (!is.integer(max.iter) || (max.iter <= 0) || (length(max.iter) != 1L)) {
    stop(sQuote("max.iter"), " must be a positive integer.")
  }

  if (!is.integer(burn.in) || (burn.in <= 0) || (burn.in >= max.iter)) {
    stop(sQuote("burn.in"), " must be a positive integer less than ", sQuote("max.iter."))
  }

  if (alg.type %not.in% c("carpviz", "carp", "carpl1", "carpvizl1")) {
    stop("Unrecognized value of ", sQuote("alg.type;"), " see help for allowed values.")
  }

  if ((t <= 1) || is.na(t) || (length(t) != 1L)) {
    stop(sQuote("t"), " must be a scalar greater than 1.")
  }

  if (!is.null(dendrogram.scale)) {
    if (dendrogram.scale %not.in% c("original", "log")) {
      stop("If not NULL, ", sQuote("dendrogram.scale"), " must be either ", sQuote("original"), " or ", sQuote("log."))
    }
  }

  list(
    obs.labels = obs.labels,
    var.labels = var.labels,
    X.center = X.center,
    X.scale = X.scale,
    rho = rho,
    phi = phi,
    k = k,
    weights = weights,
    weight.dist = weight.dist,
    weight.dist.p = weight.dist.p,
    max.iter = max.iter,
    burn.in = burn.in,
    alg.type = alg.type,
    t = t,
    npcs = npcs,
    dendrogram.scale = dendrogram.scale
  )
}

#' Print \code{CARP} Results
#'
#' Prints a brief descripton of a fitted \code{CARP} object.
#'
#' Reports number of observations and variables of dataset, any preprocessing
#' done by the \code{\link{CARP}} function, regularization weight information,
#' and the variant of \code{CARP} used.
#'
#' @param x an object of class \code{CARP} as returned by \code{\link{CARP}}
#' @param ... Additional unused arguments
#' @export
#' @examples
#' carp_fit <- CARP(presidential_speech[1:10,1:4])
#' print(carp_fit)
print.CARP <- function(x, ...) {
  alg_string <- switch(x$alg.type,
                       carp      = paste0("CARP (t = ", round(x$t, 3), ")"),
                       carpl1    = paste0("CARP (t = ", round(x$t, 3), ") [L1]"),
                       carpviz   = "CARP-VIZ",
                       carpvizl1 = "CARP-VIZ [L1]")

  cat("CARP Fit Summary\n")
  cat("====================\n\n")
  cat("Algorithm: ", alg_string, "\n\n")

  cat("Number of Observations: ", x$n.obs, "\n")
  cat("Number of Variables:    ", x$p.var, "\n\n")

  cat("Pre-processing options:\n")
  cat(" - Columnwise centering: ", x$X.center, "\n")
  cat(" - Columnwise scaling:   ", x$X.scale, "\n\n")

  cat("RBF Kernel Weights:\n") # TODO: Add descriptions of what these parameters represent
  cat(" - phi = ", round(x$phi, 3), "\n")
  cat(" - K   = ", x$k, "\n\n")

  cat("Raw Data:\n")
  print(x$X[1:min(5, x$n.obs), 1:min(5, x$p.var)])

  invisible(x)
}
