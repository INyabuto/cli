
#' @importFrom utils globalVariables

if (getRversion() >= "2.15.1") globalVariables("app")

inline_generic <- function(app, x, style) {
  vec_style <- attr(x, "cli_style")
  before <- vec_style$before %||% style$before
  after <- vec_style$after %||% style$after
  fmt <- vec_style$fmt %||% style$fmt
  xx <- paste0(before, x, after)
  if (!is.null(fmt)) xx <- vcapply(xx, fmt)
  xx
}

inline_collapse <- function(x, style = list()) {
  vec_style <- attr(x, "cli_style")
  sep <- vec_style$vec_sep %||%
    style$vec_sep %||%
    ", "
  last <- vec_style$vec_last %||%
    style$vec_last %||%
    if (length(x) >= 3) ", and " else " and "
  glue_collapse(x, sep = sep, last = last)
}

#' @importFrom glue glue glue_collapse

inline_transformer <- local({
  inline_styling <- FALSE
  transform_hook <- function(x, ...) x
  style <- list()
  function(code, envir) {
    failed <- FALSE
    res <- suppressWarnings(tryCatch({
      expr <- parse(text = code, keep.source = FALSE)
      transform_hook(eval(expr, envir = envir), style = style)
    }, error = function(e) failed <<- TRUE ))

    if (!failed) {
      if (inline_styling) return(res)
      rcls <- class(res)
      stls <- app$get_current_style()$`class-map`
      cls <- na.omit(match(rcls, names(stls)))[1]
      if (is.na(cls)) class <- NULL else class <- stls[[cls]]
      vec_style <- attr(res, "cli_style")
      tid <- if (!is.null(vec_style)) {
        app$add_theme(list(span = vec_style))
      }
      id <- clii__container_start(app, "span", class = class, theme = tid)
      on.exit(clii__container_end(app, id), add = TRUE)
      style_save <- style
      on.exit(style <<- style_save, add = TRUE)
      style <<- app$get_current_style()
      res <- structure(
        inline_generic(app, res, style),
        cli_style = attr(res, "cli_style")
      )
      return(inline_collapse(res, style))
    }

    code <- glue_collapse(code, "\n")
    m <- regexpr(inline_regex(), code, perl = TRUE)
    has_match <- m != -1
    if (!has_match) return(paste0("{", code, "}"))

    starts <- attr(m, "capture.start")
    ends <- starts + attr(m, "capture.length") - 1L
    captures <- substring(code, starts, ends)
    funname <- captures[[1]]
    text <- captures[[2]]

    inline_styling <<- TRUE
    on.exit(inline_styling <<- FALSE, add = TRUE)

    id <- clii__container_start(app, "span", class = funname)
    on.exit(clii__container_end(app, id), add = TRUE)
    style_save <- style
    on.exit(style <<- style_save, add = TRUE)
    style <<- app$get_current_style()
    transform_hook_save <- transform_hook
    on.exit(transform_hook <<- transform_hook_save, add = TRUE)
    if (is.function(style$transform)) {
      transform_hook <<- style$transform
    }

    out <- glue(
      text,
      .envir = envir,
      .transformer = inline_transformer,
      .open = paste0("{", envir$marker),
      .close = paste0(envir$marker, "}")
    )

    inline_collapse(
      inline_generic(app, out, style = style),
      style = style
    )
  }
})

clii__inline <- function(app, text, .list) {
  ## Inject that app, so we can style
  assign("app", app, envir = environment(inline_transformer))
  on.exit(rm(list = "app", envir = environment(inline_transformer)), add = TRUE)
  texts <- c(if (!is.null(text)) list(text), .list)
  out <- lapply(texts, function(t) {
    glue(
      t$str,
      .envir = t$values,
      .transformer = inline_transformer,
      .open = paste0("{", t$values$marker),
      .close = paste0(t$values$marker, "}")
    )
  })
  paste(out, collapse = "")
}

inline_regex <- function() "(?s)^[.]([-[:alnum:]_]+)[[:space:]]+(.+)"

make_cmd_transformer <- function(values) {
  values$marker <- random_id()
  values$qty <- NA_integer_
  values$num_subst <- 0L
  values$postprocess <- FALSE
  values$pmarkers <- list()

  function(code, envir) {
    res <- tryCatch({
      expr <- parse(text = code, keep.source = FALSE)
      eval(expr, envir = list("?" = function(...) stop()), enclos = envir)
    }, error = function(e) e)

    if (!inherits(res, "error")) {
      id <- paste0("v", length(values))
      if (length(res) == 0) res <- qty(0)
      values[[id]] <- res
      values$qty <- res
      values$num_subst <- values$num_subst + 1L
      return(paste0("{", values$marker, id, values$marker, "}"))
    }

    # plurals
    if (substr(code, 1, 1) == "?") {
      return(parse_plural(code, values))

    } else {
      # inline styles
      m <- regexpr(inline_regex(), code, perl = TRUE)
      has_match <- m != -1
      if (!has_match) stop(res)

      starts <- attr(m, "capture.start")
      ends <- starts + attr(m, "capture.length") - 1L
      captures <- substring(code, starts, ends)
      funname <- captures[[1]]
      text <- captures[[2]]

      out <- glue(text, .envir = envir, .transformer = sys.function())
      paste0("{", values$marker, ".", funname, " ", out, values$marker, "}")
    }
  }
}

glue_cmd <- function(..., .envir) {
  str <- paste0(unlist(list(...), use.names = FALSE), collapse = "")
  values <- new.env(parent = emptyenv())
  transformer <- make_cmd_transformer(values)
  pstr <- glue(str, .envir = .envir, .transformer = transformer)
  glue_delay(
    str = post_process_plurals(pstr, values),
    values = values
  )
}

glue_delay <- function(str, values = NULL) {
  structure(
    list(str = str, values = values),
    class = "cli_glue_delay"
  )
}
