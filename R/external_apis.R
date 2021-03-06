#' Retrieve gene names from biomaRt
#'
#' @param ensembl.genes character vector with gene names in ensembl_id format
#'
#' @return a dataframe with external gene names, ensembl_id and heatmap plot
#' @export
#'
#' @examples
#' gene.names(c('ENSG00000114978','ENSG00000166211', 'ENSG00000183688'))
gene.names <- function(ensembl.genes) {
  tryCatch({
    marts <- biomaRt::listMarts()
    index <- grep("ensembl genes",marts$version, ignore.case = TRUE)
    mart <- biomaRt::useMart(marts$biomart[index])
    mart <- loose.rock::run.cache(biomaRt::useMart,
                                  marts$biomart[index],
                                  'hsapiens_gene_ensembl',
                                  cache.prefix = 'biomart')
    results <- biomaRt::getBM(attributes = c("external_gene_name", "ensembl_gene_id"),
                              filters = "ensembl_gene_id", values = ensembl.genes,
                              mart = mart)
    return(dplyr::arrange(results, external_gene_name))
  }, error = function(msg) {
    flog.warn('Error when finding gene names:\n\t%s', msg)
  })
  return(data.frame(ensembl_gene_id = ensembl.genes, external_gene_name = ensembl.genes, stringsAsFactors = FALSE))
}

#' Retrieve hallmarks of cancer count for genes
#'
#' @param genes gene names
#' @param metric see below
#' @param hierarchy see below
#'
#' @return data.frame with choosen metric and hierarchy
#' It also returns a vector with genes that do not have any
#' hallmarks.
#'
#' See http://chat.lionproject.net/api for more details on the
#' metric and hallmarks parameters
#'
#' To standardize the colors in the gradient you can use
#' scale_fill_gradientn(limits=c(0,1), colours=topo.colors(3)) to
#' limit between 0 and 1 for cprob and -1 and 1 for npmi
#'
#' @export
#'
#' @examples
#' hallmarks(c('MOB1A', 'RFLNB', 'SPIC'))
#' hallmarks(c('MOB1A', 'RFLNB', 'SPIC'), metric = 'cprob')
hallmarks <- function(genes, metric = 'count', hierarchy = 'full', generate.plot = TRUE, show.message = FALSE) {
  valid.measures <- c('count', 'cprob', 'pmi', 'npmi')
  if (!metric %in% valid.measures) {
    stop(sprintf('measure argument is not valid, it must be one of the followin: %s', paste(valid.measures, collapse = ', ')))
  }


  all.genes <- sort(unique(genes))


  if (metric == 'cprob') {
    temp.res <- hallmarks(all.genes, metric = 'count', hierarchy = 'full', show.message = FALSE, generate.plot = FALSE)
    good.ix <- rowSums(temp.res$hallmarks) != 0
    all.genes <- sort(unique(rownames(temp.res$hallmarks[good.ix,])))
    df.no.hallmarks <- temp.res$no.hallmakrs
    #
    cat('There is a bug in the Hallmarks\' API that requires the function to wait around 5 additional seconds to finish. Sorry.\n  bug report: https://github.com/cambridgeltl/chat/issues/6\n')
    Sys.sleep(5.5)
  } else {
    df.no.hallmarks <- NULL
  }

  base.url <- sprintf('http://chat.lionproject.net/chartdata?measure=%s&hallmarks=%s', metric, hierarchy)
  # base.url <- 'http://chat.lionproject.net/?measure=npmi&chart_type=doughnut&hallmarks=full'

  call.url <- sprintf('%s&q=%s', base.url, paste(all.genes, collapse = '&q='))

  conn <- url(call.url, open = 'rt')
  lines <- readLines(conn)
  close.connection(conn, type = 'r') # close connection
  item_group <- cumsum(grepl(sprintf("^[A-Za-z0-9\\._,-]+\t%s", metric), lines))
  all.items <- list()
  col.names <- c()
  clean.rows <- lapply(split(lines, item_group), function(ix) {
    item.id <- gsub(sprintf("\t%s", metric),"", ix[1])
    # prepare results
    item.val <- list()
    my.names <- c('gene.name')
    my.values <- c(item.id)
    for (line in ix[-1]) {
      if (line == '') {
        next
      }
      my.split <- strsplit(line, '\t')[[1]]
      # flog.info('  %s -- %s',my.split[1], my.split[2] )
      my.names  <- c(my.names, my.split[1])
      my.values <- c(my.values, as.numeric(my.split[2]))
      col.names <<- c(col.names, my.split[[1]])
    }
    names(my.values) <- my.names
    all.items[[item.id]] <- my.values
  })

  col.names <- unique(col.names)
  df <- data.frame()
  for (ix in clean.rows) {
    # convert to numeric
    new.ix <- as.numeric(ix[names(ix) != 'gene.name'])
    # set previous names
    names(new.ix) <- names(ix)[names(ix) != 'gene.name']
    # create temporary data frame with controlled column names
    temp.df <- data.frame(t(new.ix[col.names]))
    rownames(temp.df) <- ix['gene.name']
    df <- rbind(df, temp.df)
  }

  df.scaled <- t(scale(t(df)))
  na.ix <- which(apply(df.scaled, 1, function(col) {
    return(all(is.nan(col)))
  }))
  df.scaled <- df # use counts

  if (is.null(df.no.hallmarks)) {
    df.no.hallmarks <- data.frame(gene.name = sort(rownames(df.scaled)[na.ix]),
                                  stringsAsFactors = FALSE)$gene.name
  }

  df.scaled <- cbind(gene.name = rownames(df.scaled), df.scaled)

  #
  # Generate heatmap
  if (generate.plot) {
    df.scaled$gene.name <- rownames(df.scaled)

    g1 <- reshape2::melt(df.scaled, id.vars = c('gene.name')) %>%
      dplyr::filter(value > 0) %>%
      ggplot2::ggplot(ggplot2::aes(gene.name, variable, fill=value)) +
        ggplot2::geom_raster() +
        ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 90, hjust = 1)) +
        ggplot2::ggtitle('Hallmarks heatmap',
                subtitle = stringr::str_wrap(sprintf('Selected genes without hallmarks (%d): %s',
                                            length(df.no.hallmarks),
                                            paste(df.no.hallmarks, collapse = ', ')),
                                    width = 50)) +
        ggplot2::xlab('External Gene Name') + ggplot2::ylab('') +
        ggplot2::scale_fill_gradientn(colours=rev(grDevices::topo.colors(2)))

  } else {
    g1 = NULL
  }

  df.scaled$gene.name <- NULL

  return(list(hallmarks = df.scaled, no.hallmakrs = df.no.hallmarks, heatmap = g1))
}
