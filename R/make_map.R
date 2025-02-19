
#' Create map to turn off and mirror parameters
#'
#' @title Create a tagged list to turn and off and mirror parameters
#'
#' @inheritParams make_data
#' @param TmbParams output from \code{\link{make_parameters}}
#' @param DataList output from \code{\link{make_data}}
#' @param Npool A user-level interface to pool hyperparameters for multiple categories.
#'              For categories with few encounters, these hyperparameters are poorly informed
#'              leading to converge difficulties.  A value \code{Npool=10} indicates
#'              that any category with fewer than \code{10} encounters across all years
#'              should have hyperparameters mirrored to the same value.
#'
#' @export
make_map <-
function( DataList,
          TmbParams,
          RhoConfig=c("Beta1"=0,"Beta2"=0,"Epsilon1"=0,"Epsilon2"=0),
          Npool=0 ){

  # Local functions
  fix_value <- function( fixvalTF ){
    vec = rep(0,length(fixvalTF))
    if(sum(fixvalTF)>0) vec[which(fixvalTF==1)] = NA
    if(sum(!fixvalTF)>0) vec[which(!is.na(vec))] = 1:sum(!is.na(vec))
    vec = factor( vec )
    return( vec )
  }
  seq_pos <- function( length.out ){
    seq(from=1, to=length.out, length.out=max(length.out,0))
  }

  # Extract Options and Options_vec (depends upon version)
  if( all(c("Options","Options_vec") %in% names(DataList)) ){
    Options_vec = DataList$Options_vec
    Options = DataList$Options
  }
  if( "Options_list" %in% names(DataList) ){
    Options_vec = DataList$Options_list$Options_vec
    Options = DataList$Options_list$Options
  }

  #### Deals with backwards compatibility for FieldConfig
  # Converts from 4-vector to 3-by-2 matrix
  if( is.vector(DataList$FieldConfig) && length(DataList$FieldConfig)==4 ){
    DataList$FieldConfig = rbind( matrix(DataList$FieldConfig,ncol=2,dimnames=list(c("Omega","Epsilon"),c("Component_1","Component_2"))), "Beta"=c("IID","IID") )
  }
  # Converts from 3-by-2 matrix to 4-by-2 matrix
  if( is.matrix(DataList$FieldConfig) & all(dim(DataList$FieldConfig)==c(3,2)) ){
    DataList$FieldConfig = rbind( DataList$FieldConfig, "Epsilon_time"=c("IID","IID") )
  }
  # Checks for errors
  if( !is.matrix(DataList$FieldConfig) || !all(dim(DataList$FieldConfig)==c(4,2)) ){
    stop("`FieldConfig` has the wrong dimensions in `make_data`")
  }
  # Renames
  dimnames(DataList$FieldConfig) = list( c("Omega","Epsilon","Beta","Epsilon_time"), c("Component_1","Component_2") )

  # FIll in Q1_ik / Q2_ik
  if( !all(c("Q1_ik","Q1_ik") %in% names(DataList)) ){
    if( "Q_ik" %in% names(DataList) ){
      DataList$Q1_ik = DataList$Q2_ik = DataList$Q_ik
    }else{
      stop("Problem with map for this version")
    }
  }

  # Fill in X1config_cp / X2config_cp for CPP versions < 10ish
  if( !all(c("X1config_cp","X2config_cp") %in% names(DataList)) ){
    if( "Xconfig_zcp" %in% names(DataList) ){
      DataList$X1config_cp = array( DataList$Xconfig_zcp[1,,], dim=dim(DataList$X1config_zcp)[2:3] )
      DataList$X2config_cp = array( DataList$Xconfig_zcp[2,,], dim=dim(DataList$X1config_zcp)[2:3] )
    }else{
      DataList$X1config_cp = DataList$X2config_cp = array( 1, dim=c(DataList$n_c,DataList$n_p) )
    }
  }

  # FIll in Q1config_k / Q2config_k for CPP versions < 10.3.0
  if( !all(c("Q1config_k","Q2config_k") %in% names(DataList)) ){
    DataList$Q1config_k = rep( 1, ncol(DataList$Q1_ik) )
    DataList$Q2config_k = rep( 1, ncol(DataList$Q2_ik) )
  }

  # Backwards compatibiliy
  if("n_p" %in% names(DataList)){
    DataList$n_p1 = DataList$n_p2 = DataList$n_p
  }

  # Convert b_i to explicit units
  if( class(DataList$b_i) == "units" ){
    b_units = units(DataList$b_i)
  }else{
    stop("`b_i` must have explicit units")
  }
  # Convert a_i to explicit units
  if( class(DataList$a_i) == "units" ){
    a_units = units(DataList$a_i)
  }else{
    stop("`a_i` must have explicit units")
  }

  # Function to identify elements of L_z corresponding to diagonal
  identify_diagonal = function( n_c, n_f ){
    M = diag(n_c)[1:n_f,,drop=FALSE]
    diagTF = M[upper.tri(M,diag=TRUE)]
    return(diagTF)
  }

  # Create tagged-list in TMB format for fixing parameters
  Map = list()

  # Turn off geometric anisotropy parameters
  if( Options_vec["Aniso"]==0 ){
    Map[['ln_H_input']] = factor( rep(NA,2) )
  }
  if( all(DataList[["FieldConfig"]][1:2,] == -1) ){
    if( !( any(DataList[["X1config_cp"]][,]%in%c(2,3,4)) | any(DataList[["X2config_cp"]][,]%in%c(2,3,4)) | any(DataList[["Q1config_k"]]%in%c(2,3)) | any(DataList[["Q2config_k"]]%in%c(2,3)) ) ){
      Map[['ln_H_input']] = factor( rep(NA,2) )
    }
  }

  #########################
  # 1. Residual variance ("logSigmaM")
  # 2. Lognormal-Poisson overdispersion ("delta_i")
  #########################

  # Measurement error models
  # NOTE:  Uses DataList$ObsModel_ez, which either exists or is added above
  Map[["logSigmaM"]] = array(NA, dim=dim(TmbParams$logSigmaM))
  if( "delta_i" %in% names(TmbParams)){
    Map[["delta_i"]] = rep(NA, length(TmbParams[["delta_i"]]) )
  }
  for( eI in seq_pos(DataList$n_e) ){
    if(DataList$ObsModel_ez[eI,1]%in%c(0,1,2,3,4)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA, NA )
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(5)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, 2 )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, 2, NA )
      if( any(DataList$ObsModel_ez[,2]!=0) ) stop("ObsModel[1]=5 should use ObsModel[2]=0")
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(6,7)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( NA, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( NA, NA, NA )
      if( any(DataList$ObsModel_ez[,2]!=0) ) stop("ObsModel[1]=6 or 7 should use ObsModel[2]=0")
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(8,10)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA, NA )
      if( any(DataList$ObsModel_ez[,2]!=2) ) stop("ObsModel[1]=8 and ObsModel[1]=10 should use ObsModel[2]=2")
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(9)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, 2 )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, 2, NA )
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(11)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA, NA )
      Map[["delta_i"]][ which((DataList$e_i+1)==eI) ] = max(c(0,Map[["delta_i"]]),na.rm=TRUE) + seq_pos(length(which((DataList$e_i+1)==eI)))
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(12,13)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( NA, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( NA, NA, NA )
      if( any(DataList$ObsModel_ez[,2]!=1) ) stop("ObsModel[1]=12 or 13 should use ObsModel[2]=1")
    }
    if(DataList$ObsModel_ez[eI,1]%in%c(14)){
      if(ncol(Map[["logSigmaM"]])==2) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA )
      if(ncol(Map[["logSigmaM"]])==3) Map[["logSigmaM"]][eI,] = max(c(0,Map[["logSigmaM"]]),na.rm=TRUE) + c( 1, NA, NA )
      Map[["delta_i"]][ which((DataList$e_i+1)==eI) ] = max(c(0,Map[["delta_i"]]),na.rm=TRUE) + seq_pos(length(which((DataList$e_i+1)==eI)))
      if( any(DataList$ObsModel_ez[,2]!=1) ) stop("ObsModel[1]=14 should use ObsModel[2]=1")
    }
  }
  Map[["logSigmaM"]] = factor(Map[["logSigmaM"]])
  if( "delta_i" %in% names(TmbParams)){
    Map[["delta_i"]] = factor(Map[["delta_i"]])
  }

  #########################
  # Variance for spatial and spatio-temporal
  #########################

  # Configurations of spatial and spatiotemporal error
  if(DataList[["FieldConfig"]][1,1] == -1){
    if("Omegainput1_sc" %in% names(TmbParams)) Map[["Omegainput1_sc"]] = factor( array(NA,dim=dim(TmbParams[["Omegainput1_sc"]])) )
    if("Omegainput1_sf" %in% names(TmbParams)) Map[["Omegainput1_sf"]] = factor( array(NA,dim=dim(TmbParams[["Omegainput1_sf"]])) )
    if("L_omega1_z" %in% names(TmbParams)) Map[["L_omega1_z"]] = factor( rep(NA,length(TmbParams[["L_omega1_z"]])) )
  }
  if(DataList[["FieldConfig"]][2,1] == -1){
    if("Epsiloninput1_sct" %in% names(TmbParams)) Map[["Epsiloninput1_sct"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput1_sct"]])) )
    if("Epsiloninput1_sft" %in% names(TmbParams)) Map[["Epsiloninput1_sft"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput1_sft"]])) )
    if("Epsiloninput1_sff" %in% names(TmbParams)) Map[["Epsiloninput1_sff"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput1_sff"]])) )
    if("L_epsilon1_z" %in% names(TmbParams)) Map[["L_epsilon1_z"]] = factor( rep(NA,length(TmbParams[["L_epsilon1_z"]])) )
  }
  if( all(DataList[["FieldConfig"]][1:2,1] == -1) ){
    if( !( any(DataList[["X1config_cp"]]%in%c(2,3,4)) | any(DataList[["Q1config_k"]]%in%c(2,3)) ) ){
      Map[["logkappa1"]] = factor(NA)
      if("rho_c1" %in% names(TmbParams)) Map[["rho_c1"]] = factor(NA)
    }
  }
  if(DataList[["FieldConfig"]][1,2] == -1){
    if("Omegainput2_sc" %in% names(TmbParams)) Map[["Omegainput2_sc"]] = factor( array(NA,dim=dim(TmbParams[["Omegainput2_sc"]])) )
    if("Omegainput2_sf" %in% names(TmbParams)) Map[["Omegainput2_sf"]] = factor( array(NA,dim=dim(TmbParams[["Omegainput2_sf"]])) )
    if("L_omega2_z" %in% names(TmbParams)) Map[["L_omega2_z"]] = factor( rep(NA,length(TmbParams[["L_omega2_z"]])) )
  }
  if(DataList[["FieldConfig"]][2,2] == -1){
    if("Epsiloninput2_sct" %in% names(TmbParams)) Map[["Epsiloninput2_sct"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput2_sct"]])) )
    if("Epsiloninput2_sft" %in% names(TmbParams)) Map[["Epsiloninput2_sft"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput2_sft"]])) )
    if("Epsiloninput2_sff" %in% names(TmbParams)) Map[["Epsiloninput2_sff"]] = factor( array(NA,dim=dim(TmbParams[["Epsiloninput2_sff"]])) )
    if("L_epsilon2_z" %in% names(TmbParams)) Map[["L_epsilon2_z"]] = factor( rep(NA,length(TmbParams[["L_epsilon2_z"]])) )
  }
  if( all(DataList[["FieldConfig"]][1:2,2] == -1 )){
    if( !( "Xconfig_zcp" %in% names(DataList) && any(DataList[["Xconfig_zcp"]][2,,] %in% c(2,3)) ) ){
      Map[["logkappa2"]] = factor(NA)
      if("rho_c2" %in% names(TmbParams)) Map[["rho_c2"]] = factor(NA)
    }
  }

  # Epsilon1 -- Fixed OR White-noise OR Random walk
  if( RhoConfig["Epsilon1"] %in% c(0,1,2) ){
    if( "Epsilon_rho1" %in% names(TmbParams) ) Map[["Epsilon_rho1"]] = factor( NA )
    if( "Epsilon_rho1_f" %in% names(TmbParams) ) Map[["Epsilon_rho1_f"]] = factor( rep(NA,length(TmbParams$Epsilon_rho1_f)) )
  }
  if( RhoConfig["Epsilon1"] %in% c(4) ){
    if( "Epsilon_rho1_f" %in% names(TmbParams) ) Map[["Epsilon_rho1_f"]] = factor( rep(1,length(TmbParams$Epsilon_rho1_f)) )
  }
  # Epsilon2 -- Fixed OR White-noise OR Random walk OR mirroring Epsilon_rho1_f
  if( RhoConfig["Epsilon2"] %in% c(0,1,2,6) ){
    if( "Epsilon_rho2" %in% names(TmbParams) ) Map[["Epsilon_rho2"]] = factor( NA )
    if( "Epsilon_rho2_f" %in% names(TmbParams) ) Map[["Epsilon_rho2_f"]] = factor( rep(NA,length(TmbParams$Epsilon_rho2_f)) )
  }
  if( RhoConfig["Epsilon2"] %in% c(4) ){
    if( "Epsilon_rho2_f" %in% names(TmbParams) ) Map[["Epsilon_rho2_f"]] = factor( rep(1,length(TmbParams$Epsilon_rho2_f)) )
  }

  # fix AR across bins
  if( DataList$n_c==1 & ("rho_c1" %in% names(TmbParams)) ){
    Map[["rho_c1"]] = factor(NA)
    Map[["rho_c2"]] = factor(NA)
  }


  #########################
  # Variance for overdispersion
  #########################

  # Overdispersion parameters
  if( ("n_f_input"%in%names(DataList)) && "n_v"%in%names(DataList) && DataList[["n_f_input"]]<0 ){
    Map[["L1_z"]] = factor(rep(NA,length(TmbParams[["L1_z"]])))
    Map[["eta1_vf"]] = factor(array(NA,dim=dim(TmbParams[["eta1_vf"]])))
    Map[["L2_z"]] = factor(rep(NA,length(TmbParams[["L2_z"]])))
    Map[["eta2_vf"]] = factor(array(NA,dim=dim(TmbParams[["eta2_vf"]])))
  }
  if( ("OverdispersionConfig"%in%names(DataList)) && "n_v"%in%names(DataList) ){
    if( DataList[["OverdispersionConfig"]][1] == -1 ){
      if("L1_z"%in%names(TmbParams)) Map[["L1_z"]] = factor(rep(NA,length(TmbParams[["L1_z"]])))
      if("L_eta1_z"%in%names(TmbParams)) Map[["L_eta1_z"]] = factor(rep(NA,length(TmbParams[["L_eta1_z"]])))
      Map[["eta1_vf"]] = factor(array(NA,dim=dim(TmbParams[["eta1_vf"]])))
    }
    if( DataList[["OverdispersionConfig"]][2] == -1 ){
      if("L2_z"%in%names(TmbParams)) Map[["L2_z"]] = factor(rep(NA,length(TmbParams[["L2_z"]])))
      if("L_eta2_z"%in%names(TmbParams)) Map[["L_eta2_z"]] = factor(rep(NA,length(TmbParams[["L_eta2_z"]])))
      Map[["eta2_vf"]] = factor(array(NA,dim=dim(TmbParams[["eta2_vf"]])))
    }
  }

  #########################
  # Npool options
  # Overwrites SigmaM, L_omega, and L_epsilon, so must come after them
  #########################

  # Make all category-specific variances (SigmaM, Omega, Epsilon) constant for models with EncNum_a < Npool
  if( Npool>0 ){
    if( !all(DataList$FieldConfig[1:3,] %in% c(-2)) | !all(DataList$FieldConfig[4,] %in% c(-3)) ){
      stop("Npool should only be specified when using 'IID' variation for `FieldConfig`")
    }
  }
  Prop_ct = abind::adrop(DataList$Options_list$metadata_ctz[,,'num_nonzero',drop=FALSE], drop=3)
  EncNum_c = rowSums( Prop_ct )
  if( any(EncNum_c < Npool) ){
    pool = function(poolTF){
      Return = 1:length(poolTF)
      Return = ifelse( poolTF==TRUE, length(poolTF)+1, Return )
      return(Return)
    }
    # Change SigmaM / L_omega1_z / L_omega2_z / L_epsilon1_z / L_epsilon2_z
    Map[["logSigmaM"]] = array( as.numeric(Map$logSigmaM), dim=dim(TmbParams$logSigmaM) )
    Map[["logSigmaM"]][ which(EncNum_c < Npool), ] = rep(1,sum(EncNum_c<Npool)) %o% Map[["logSigmaM"]][ which(EncNum_c < Npool)[1], ]
    Map[["logSigmaM"]] = factor( Map[["logSigmaM"]] )
    # Change Omegas
    Map[["L_omega1_z"]] = factor(pool(EncNum_c<Npool))
    Map[["L_omega2_z"]] = factor(pool(EncNum_c<Npool))
    # Change Epsilons
    Map[["L_epsilon1_z"]] = factor(pool(EncNum_c<Npool))
    Map[["L_epsilon2_z"]] = factor(pool(EncNum_c<Npool))
  }

  #########################
  # Covariates
  #########################

  # Static covariates
    # Deprecated >= V6.0.0
  if( "X_xj" %in% names(DataList) ){
    Var_j = apply( DataList[["X_xj"]], MARGIN=2, FUN=var )
    Map[["gamma1_j"]] = Map[["gamma2_j"]] = seq_pos(ncol(DataList$X_xj))
    for(j in seq_pos(length(Var_j))){
      if( Var_j[j]==0 ){
        Map[["gamma1_j"]][j] = NA
        Map[["gamma2_j"]][j] = NA
      }
    }
    Map[["gamma1_j"]] = factor(Map[["gamma1_j"]])
    Map[["gamma2_j"]] = factor(Map[["gamma2_j"]])
  }

  ### Catchability variables
  if( all(c("Q1_ik","Q2_ik") %in% names(DataList)) ){
    Var1_k = apply( DataList[["Q1_ik"]], MARGIN=2, FUN=var )
    Var2_k = apply( DataList[["Q2_ik"]], MARGIN=2, FUN=var )
    Map[["lambda1_k"]] = seq_pos(ncol(DataList$Q1_ik))
    Map[["lambda2_k"]] = seq_pos(ncol(DataList$Q2_ik))
    for(k in seq_pos(length(Var1_k))){
      if( Var1_k[k]==0 ){
        Map[["lambda1_k"]][k] = NA
      }
    }
    for(k in seq_pos(length(Var2_k))){
      if( Var2_k[k]==0 ){
        Map[["lambda2_k"]][k] = NA
      }
    }
    for(kI in seq_pos(ncol(DataList$Q1_ik))){
      if( DataList$Q1config_k[kI] %in% c(-1,0,2) ){
        Map[["lambda1_k"]][kI] = NA
      }
    }
    for(kI in seq_pos(ncol(DataList$Q2_ik))){
      if( DataList$Q2config_k[kI] %in% c(-1,0,2) ){
        Map[["lambda2_k"]][kI] = NA
      }
    }
    Map[["lambda1_k"]] = factor(Map[["lambda1_k"]])
    Map[["lambda2_k"]] = factor(Map[["lambda2_k"]])

    if( all(c("log_sigmaPhi1_k","log_sigmaPhi2_k") %in% names(TmbParams)) ){
      Map[["log_sigmaPhi1_k"]] = seq_pos(ncol(DataList$Q1_ik))
      Map[["log_sigmaPhi2_k"]] = seq_pos(ncol(DataList$Q2_ik))
      for(kI in seq_pos(ncol(DataList$Q1_ik))){
        if( DataList$Q1config_k[kI] %in% c(0,1) ){
          Map[["log_sigmaPhi1_k"]][kI] = NA
        }
      }
      for(kI in seq_pos(ncol(DataList$Q2_ik))){
        if( DataList$Q2config_k[kI] %in% c(0,1) ){
          Map[["log_sigmaPhi2_k"]][kI] = NA
        }
      }
      Map[["log_sigmaPhi1_k"]] = factor(Map[["log_sigmaPhi1_k"]])
      Map[["log_sigmaPhi2_k"]] = factor(Map[["log_sigmaPhi2_k"]])
    }
  }

  # Dynamic covariates
  if( any(c("X_xtp","X_itp","X_ip","X1_ip") %in% names(DataList)) ){
    if( "X_xtp" %in% names(DataList) ){
      Var1_p = Var2_p = apply( DataList[["X_xtp"]], MARGIN=3, FUN=function(array){var(as.vector(array))})
      Var1_tp = Var2_tp = apply( DataList[["X_xtp"]], MARGIN=2:3, FUN=var )
    }
    if( "X_itp" %in% names(DataList) ){
      Var1_p = Var2_p = apply( DataList[["X_itp"]], MARGIN=3, FUN=function(array){var(as.vector(array))})
      Var1_tp = Var2_tp = apply( DataList[["X_itp"]], MARGIN=2:3, FUN=var )
    }
    if( "X_ip" %in% names(DataList) ){
      Var1_p = Var2_p = apply( DataList[["X_ip"]], MARGIN=2, FUN=function(array){var(as.vector(array))})
    }
    if( "X1_ip" %in% names(DataList) ){
      Var1_p = apply( DataList[["X1_ip"]], MARGIN=2, FUN=function(array){var(as.vector(array))})
      Var2_p = apply( DataList[["X2_ip"]], MARGIN=2, FUN=function(array){var(as.vector(array))})
    }
    if( "gamma1_tp" %in% names(TmbParams) ){
      Map[["gamma1_tp"]] = matrix( seq_pos(DataList$n_t*DataList$n_p1), nrow=DataList$n_t, ncol=DataList$n_p1 )
      Map[["gamma2_tp"]] = matrix( seq_pos(DataList$n_t*DataList$n_p2), nrow=DataList$n_t, ncol=DataList$n_p2 )
      # By default:
      #  1.  turn off coefficient associated with variable having no variance across space and time
      #  2.  assume constant coefficient for all years of each variable and category
      for(p in seq_pos(length(Var1_p))){
        if( Var1_p[p]==0 ){
          Map[["gamma1_tp"]][,p] = NA
          Map[["gamma2_tp"]][,p] = NA
        }else{
          Map[["gamma1_tp"]][,p] = rep( Map[["gamma1_tp"]][1,p], DataList$n_t )
          Map[["gamma2_tp"]][,p] = rep( Map[["gamma2_tp"]][1,p], DataList$n_t )
        }
      }
      Map[["gamma1_tp"]] = factor(Map[["gamma1_tp"]])
      Map[["gamma2_tp"]] = factor(Map[["gamma2_tp"]])
    }
    if( all(c("gamma1_ctp","gamma2_ctp") %in% names(TmbParams)) ){
      Map[["gamma1_ctp"]] = array( seq_pos(DataList$n_c*DataList$n_t*DataList$n_p1), dim=c(DataList$n_c,DataList$n_t,DataList$n_p1) )
      Map[["gamma2_ctp"]] = array( seq_pos(DataList$n_c*DataList$n_t*DataList$n_p2), dim=c(DataList$n_c,DataList$n_t,DataList$n_p2) )
      # By default:
      #  1.  turn off coefficient associated with variable having no variance across space and time
      #  2.  assume constant coefficient for all years of each variable and category
      for(p in seq_pos(length(Var1_p))){
        if( Var1_p[p]==0 ){
          Map[["gamma1_ctp"]][,,p] = NA
          Map[["gamma2_ctp"]][,,p] = NA
        }else{
          for(cI in 1:DataList$n_c){
            Map[["gamma1_ctp"]][cI,,p] = rep( Map[["gamma1_ctp"]][cI,1,p], DataList$n_t )
            Map[["gamma2_ctp"]][cI,,p] = rep( Map[["gamma2_ctp"]][cI,1,p], DataList$n_t )
          }
        }
      }
      if( "Xconfig_zcp" %in% names(DataList) ){
        for(cI in 1:DataList$n_c){
        for(pI in seq_pos(DataList$n_p1)){
          if( DataList$Xconfig_zcp[1,cI,pI] %in% c(-1,0,2) ){
            Map[["gamma1_ctp"]][cI,,pI] = NA
          }
          if( DataList$Xconfig_zcp[2,cI,pI] %in% c(-1,0,2) ){
            Map[["gamma2_ctp"]][cI,,pI] = NA
          }
        }}
      }
      Map[["gamma1_ctp"]] = factor(Map[["gamma1_ctp"]])
      Map[["gamma2_ctp"]] = factor(Map[["gamma2_ctp"]])
    }
    if( all(c("gamma1_cp","gamma2_cp") %in% names(TmbParams)) ){
      Map[["gamma1_cp"]] = array( seq_pos(DataList$n_c*DataList$n_p1), dim=c(DataList$n_c,DataList$n_p1) )
      Map[["gamma2_cp"]] = array( seq_pos(DataList$n_c*DataList$n_p2), dim=c(DataList$n_c,DataList$n_p2) )
      # By default, turn off coefficient associated with variable having no variance across space and time
      for(p in seq_pos(length(Var1_p))){
        if( Var1_p[p]==0 ){
          Map[["gamma1_cp"]][,p] = NA
        }
      }
      for(p in seq_pos(length(Var2_p))){
        if( Var2_p[p]==0 ){
          Map[["gamma2_cp"]][,p] = NA
        }
      }
      for(cI in 1:DataList$n_c){
      for(pI in seq_pos(DataList$n_p1)){
        if( DataList$X1config_cp[cI,pI] %in% c(-1,0,2,4) ){
          Map[["gamma1_cp"]][cI,pI] = NA
        }
      }}
      for(cI in 1:DataList$n_c){
      for(pI in seq_pos(DataList$n_p2)){
        if( DataList$X2config_cp[cI,pI] %in% c(-1,0,2,4) ){
          Map[["gamma2_cp"]][cI,pI] = NA
        }
      }}
      Map[["gamma1_cp"]] = factor(Map[["gamma1_cp"]])
      Map[["gamma2_cp"]] = factor(Map[["gamma2_cp"]])
    }
    if( all(c("log_sigmaXi1_cp","log_sigmaXi2_cp") %in% names(TmbParams)) ){
      Map[["log_sigmaXi1_cp"]] = array( seq_pos(DataList$n_c*DataList$n_p1), dim=c(DataList$n_c,DataList$n_p1) )
      Map[["log_sigmaXi2_cp"]] = array( seq_pos(DataList$n_c*DataList$n_p2), dim=c(DataList$n_c,DataList$n_p2) )
      if( "Xconfig_zcp" %in% names(DataList) ){
        for(cI in 1:DataList$n_c){
        for(pI in seq_pos(DataList$n_p1)){
          if( DataList$Xconfig_zcp[1,cI,pI] %in% c(0,1) ){
            Map[["log_sigmaXi1_cp"]][cI,pI] = NA
          }
          if( DataList$Xconfig_zcp[2,cI,pI] %in% c(0,1) ){
            Map[["log_sigmaXi2_cp"]][cI,pI] = NA
          }
        }}
      }
      if( all(c("X1config_cp","X2config_cp") %in% names(DataList)) ){
        for(cI in 1:DataList$n_c){
        for(pI in seq_pos(DataList$n_p1)){
          if( DataList$X1config_cp[cI,pI] %in% c(0,1) ){
            Map[["log_sigmaXi1_cp"]][cI,pI] = NA
          }
        }}
        for(cI in 1:DataList$n_c){
        for(pI in seq_pos(DataList$n_p2)){
          if( DataList$X2config_cp[cI,pI] %in% c(0,1) ){
            Map[["log_sigmaXi2_cp"]][cI,pI] = NA
          }
        }}
      }
      Map[["log_sigmaXi1_cp"]] = factor(Map[["log_sigmaXi1_cp"]])
      Map[["log_sigmaXi2_cp"]] = factor(Map[["log_sigmaXi2_cp"]])
    }
  }

  # Spatially varying coefficients -- density
  if( all(c("Xiinput1_scp","Xiinput2_scp") %in% names(TmbParams)) ){
    Map[["Xiinput1_scp"]] = array( seq_pos(DataList$n_s*DataList$n_c*DataList$n_p1), dim=c(DataList$n_s,DataList$n_c,DataList$n_p1) )
    Map[["Xiinput2_scp"]] = array( seq_pos(DataList$n_s*DataList$n_c*DataList$n_p2), dim=c(DataList$n_s,DataList$n_c,DataList$n_p2) )
    if( "Xconfig_zcp" %in% names(DataList) ){
      for(cI in 1:DataList$n_c){
      for(pI in seq_pos(DataList$n_p1)){
        if(DataList$X1config_cp[cI,pI] %in% c(0,1)) Map[["Xiinput1_scp"]][,cI,pI] = NA
        if(DataList$X2config_cp[cI,pI] %in% c(0,1)) Map[["Xiinput2_scp"]][,cI,pI] = NA
      }}
    }
    if( all(c("X1config_cp","X2config_cp") %in% names(DataList)) ){
      for(cI in 1:DataList$n_c){
      for(pI in seq_pos(DataList$n_p1)){
        if(DataList$X1config_cp[cI,pI] %in% c(0,1)) Map[["Xiinput1_scp"]][,cI,pI] = NA
      }}
      for(cI in 1:DataList$n_c){
      for(pI in seq_pos(DataList$n_p2)){
        if(DataList$X2config_cp[cI,pI] %in% c(0,1)) Map[["Xiinput2_scp"]][,cI,pI] = NA
      }}
    }
    Map[["Xiinput1_scp"]] = factor(Map[["Xiinput1_scp"]])
    Map[["Xiinput2_scp"]] = factor(Map[["Xiinput2_scp"]])
  }

  # Spatially varying coefficients -- catchability
  if( all(c("Phiinput1_sk","Phiinput2_sk") %in% names(TmbParams)) ){
    Map[["Phiinput1_sk"]] = array( seq_pos(prod(dim(TmbParams$Phiinput1_sk))), dim=dim(TmbParams$Phiinput1_sk) )
    Map[["Phiinput2_sk"]] = array( seq_pos(prod(dim(TmbParams$Phiinput2_sk))), dim=dim(TmbParams$Phiinput2_sk) )
    for(kI in seq_pos(ncol(DataList$Q1_ik))){
      if(DataList$Q1config_k[kI] %in% c(0,1)) Map[["Phiinput1_sk"]][,kI] = NA
    }
    for(kI in seq_pos(ncol(DataList$Q2_ik))){
      if(DataList$Q2config_k[kI] %in% c(0,1)) Map[["Phiinput2_sk"]][,kI] = NA
    }
    Map[["Phiinput1_sk"]] = factor(Map[["Phiinput1_sk"]])
    Map[["Phiinput2_sk"]] = factor(Map[["Phiinput2_sk"]])
  }

  # Lagrange multipliers
  # Only enabled when X1config_cp[,]=4 AND Options[20]=4
  if( "lagrange_tc" %in% names(TmbParams) ){
    if( !(Options[20]==4 & (any(DataList$X1config_cp==4) | any(DataList$X2config_cp==4))) ){
      Map[["lagrange_tc"]] = factor( array(NA, dim=c(DataList$n_t,DataList$n_c)) )
    }
  }

  #########################
  # Seasonal models
  #########################

  # fix variance-ratio for columns of t_iz
  if( "log_sigmaratio1_z" %in% names(TmbParams) ){
    Map[["log_sigmaratio1_z"]] = factor( NA )
  }
  if( "log_sigmaratio2_z" %in% names(TmbParams) ){
    Map[["log_sigmaratio2_z"]] = factor( NA )
  }

  #########################
  # Interactions
  #########################

  if( "VamConfig"%in%names(DataList) & all(c("Chi_fr","Psi_fr")%in%names(TmbParams)) ){
    # Turn off interactions
    if( DataList$VamConfig[1]==0 ){
      Map[["Chi_fr"]] = factor( rep(NA,prod(dim(TmbParams$Chi_fr))) )
      Map[["Psi_fr"]] = factor( rep(NA,prod(dim(TmbParams$Psi_fr))) )
    }
    # Reduce degrees of freedom for interactions
    if( DataList$VamConfig[1] %in% c(1,3) ){
      Map[["Psi_fr"]] = array( seq_pos(prod(dim(TmbParams$Psi_fr))), dim=dim(TmbParams$Psi_fr) )
      Map[["Psi_fr"]][seq_pos(ncol(Map[["Psi_fr"]])),] = NA
      Map[["Psi_fr"]] = factor(Map[["Psi_fr"]])
    }
    # Reduce degrees of freedom for interactions
    if( DataList$VamConfig[1]==2 ){
      Map[["Psi_fr"]] = array( 1:prod(dim(TmbParams$Psi_fr)), dim=dim(TmbParams$Psi_fr) )
      Map[["Psi_fr"]][1:ncol(Map[["Psi_fr"]]),] = NA
      Map[["Psi_fr"]] = factor(Map[["Psi_fr"]])
      Map[["Psi_fr"]] = array( 1:prod(dim(TmbParams$Psi_fr)), dim=dim(TmbParams$Psi_fr) )
      Map[["Psi_fr"]][1:ncol(Map[["Psi_fr"]]),] = NA
      Map[["Psi_fr"]][cbind(1:ncol(Map[["Psi_fr"]]),1:ncol(Map[["Psi_fr"]]))] = max(c(0,Map[["Psi_fr"]]),na.rm=TRUE) + 1:ncol(Map[["Psi_fr"]])
      Map[["Psi_fr"]] = factor(Map[["Psi_fr"]])
    }
  }

  #########################
  # 1. Intercepts
  # 2. Hyper-parameters for intercepts
  #########################

  #####
  # Step 1: fix betas and/or epsilons for missing years if betas are fixed-effects
  #####
  Num_ct = abind::adrop(DataList$Options_list$metadata_ctz[,,'num_notna',drop=FALSE], drop=3)
  if( any(Num_ct==0) ){
    # Beta1 -- Fixed
    if( RhoConfig["Beta1"]==0 ){
      if( "beta1_ct" %in% names(TmbParams) ){
        Map[["beta1_ct"]] = fix_value( fixvalTF=(Num_ct==0) )
      }
      if( "beta1_ft" %in% names(TmbParams) ){
        if( DataList[["FieldConfig"]][3,1] == -2 ){
          Map[["beta1_ft"]] = fix_value( fixvalTF=(Num_ct==0) )
        }else{
          stop( "Missing years may not work using a factor-model for intercepts" )
        }
      }
    }else{
      # Don't fix because it would affect estimates of variance
    }
    # Beta2 -- Fixed
    if( RhoConfig["Beta2"]==0 ){
      if( "beta2_ct" %in% names(TmbParams) ){
        Map[["beta2_ct"]] = fix_value( fixvalTF=(Num_ct==0) )
      }
      if( "beta2_ft" %in% names(TmbParams) ){
        if( DataList[["FieldConfig"]][3,2] == -2 ){
          Map[["beta2_ft"]] = fix_value( fixvalTF=(Num_ct==0) )
        }else{
          stop( "Missing years may not work using a factor-model for intercepts" )
        }
      }
    }else{
      # Don't fix because it would affect estimates of variance
    }
  }

  #####
  # Step 2: User settings for 100% encounter rates
  # overwrite previous, but also re-checks for missing data
  #####

  Use_informative_starts = FALSE
  if( all(c("beta1_ct","beta2_ct") %in% names(TmbParams)) ){
    Use_informative_starts = TRUE
  }
  if( all(c("beta1_ft","beta2_ft") %in% names(TmbParams)) ){
    if( all(DataList$FieldConfig[3,1:2] == -2) ){
      Use_informative_starts = TRUE
    }
  }
  if( Use_informative_starts==TRUE ){
    # Temporary object for mapping
    Map_tmp = list( "beta1_ct"=NA, "beta2_ct"=NA )

    # Change beta1_ct if 100% encounters (not designed to work with seasonal models)
    if( any(DataList$ObsModel_ez[,2] %in% c(3)) ){
      if( ncol(DataList$t_iz)==1 ){
        Prop_ct = abind::adrop(DataList$Options_list$metadata_ctz[,,'prop_nonzero',drop=FALSE], drop=3)
        Map_tmp[["beta1_ct"]] = array( 1:prod(dim(Prop_ct)), dim=dim(Prop_ct) )
        Map_tmp[["beta1_ct"]][which(is.na(Prop_ct) | Prop_ct==1)] = NA
        # MAYBE ADD FEATURE TO TURN OFF FOR Prop_ct==0
      }else{
        stop("`ObsModel[,2]==3` is not implemented to work with seasonal models")
      }
    }

    # Change beta1_ct and beta2_ct if 0% or 100% encounters (not designed to work with seasonal models)
    if( any(DataList$ObsModel_ez[,2] %in% c(4)) ){
      if( ncol(DataList$t_iz)==1 ){
        Prop_ct = abind::adrop(DataList$Options_list$metadata_ctz[,,'prop_nonzero',drop=FALSE], drop=3)
        Map_tmp[["beta1_ct"]] = array( 1:prod(dim(Prop_ct)), dim=dim(Prop_ct) )
        Map_tmp[["beta1_ct"]][which(is.na(Prop_ct) | Prop_ct==1 | Prop_ct==0)] = NA
        Map_tmp[["beta2_ct"]] = array( 1:prod(dim(Prop_ct)), dim=dim(Prop_ct) )
        Map_tmp[["beta2_ct"]][which(is.na(Prop_ct) | Prop_ct==0)] = NA
      }else{
        stop("`ObsModel[,2]==3` is not implemented to work with seasonal models")
      }
    }

    # Insert with name appropriate for a given version
    if( all(c("beta1_ct","beta2_ct") %in% names(TmbParams)) ){
      if( length(Map_tmp[["beta1_ct"]])>1 || !is.na(Map_tmp[["beta1_ct"]]) ) Map[["beta1_ct"]] = factor(Map_tmp[["beta1_ct"]])
      if( length(Map_tmp[["beta2_ct"]])>1 || !is.na(Map_tmp[["beta2_ct"]]) ) Map[["beta2_ct"]] = factor(Map_tmp[["beta2_ct"]])
    }
    if( all(c("beta1_ft","beta2_ft") %in% names(TmbParams)) ){
      if( length(Map_tmp[["beta1_ct"]])>1 || !is.na(Map_tmp[["beta1_ct"]]) ) Map[["beta1_ft"]] = factor(Map_tmp[["beta1_ct"]])
      if( length(Map_tmp[["beta2_ct"]])>1 || !is.na(Map_tmp[["beta2_ct"]]) ) Map[["beta2_ft"]] = factor(Map_tmp[["beta2_ct"]])
    }
  }

  #####
  # Step 3: Structure for hyper-parameters
  # overwrites previous structure on intercepts only if temporal structure is specified (in which case its unnecessary)
  #####

  # Hyperparameters for intercepts for <= V5.3.0
  if( all(c("logsigmaB1","logsigmaB2") %in% names(TmbParams)) ){
    if( RhoConfig["Beta1"]==0){
      Map[["Beta_mean1"]] = factor( NA )
      Map[["Beta_rho1"]] = factor( NA )
      Map[["logsigmaB1"]] = factor( NA )
    }
    # Beta1 -- White-noise
    if( RhoConfig["Beta1"]==1){
      Map[["Beta_rho1"]] = factor( NA )
    }
    # Beta1 -- Random-walk
    if( RhoConfig["Beta1"]==2){
      Map[["Beta_mean1"]] = factor( NA )
      Map[["Beta_rho1"]] = factor( NA )
    }
    # Beta1 -- Constant over time for each category
    if( RhoConfig["Beta1"]==3){
      Map[["Beta_mean1"]] = factor( NA )
      Map[["Beta_rho1"]] = factor( NA )
      Map[["logsigmaB1"]] = factor( NA )
      Map[["beta1_ct"]] = factor( 1:DataList$n_c %o% rep(1,DataList$n_t) )
    }
    # Beta2 -- Fixed (0) or Beta_rho2 mirroring Beta_rho1 (6)
    if( RhoConfig["Beta2"] %in% c(0,6) ){
      Map[["Beta_mean2"]] = factor( NA )
      Map[["Beta_rho2"]] = factor( NA )
      Map[["logsigmaB2"]] = factor( NA )
    }
    # Beta2 -- White-noise
    if( RhoConfig["Beta2"]==1){
      Map[["Beta_rho2"]] = factor( NA )
    }
    # Beta2 -- Random-walk
    if( RhoConfig["Beta2"]==2){
      Map[["Beta_mean2"]] = factor( NA )
      Map[["Beta_rho2"]] = factor( NA )
    }
    # Beta2 -- Constant over time for each category
    if( RhoConfig["Beta2"]==3){
      Map[["Beta_mean2"]] = factor( NA )
      Map[["Beta_rho2"]] = factor( NA )
      Map[["logsigmaB2"]] = factor( NA )
      Map[["beta2_ct"]] = factor( 1:DataList$n_c %o% rep(1,DataList$n_t) )
    }
    # Warnings
    if( DataList$n_c >= 2 ){
      warnings( "This version of VAST has the same hyperparameters for the intercepts of all categories.  Please use CPP version >=5.4.0 for different hyperparameters for each category." )
    }
  }
  # Hyperparameters for intercepts for >= V5.4.0 & <7.0.0
  if( all(c("logsigmaB1_c","logsigmaB2_c") %in% names(TmbParams)) ){
    if( RhoConfig["Beta1"]==0){
      Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["logsigmaB1_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta1 -- White-noise
    if( RhoConfig["Beta1"]==1){
      Map[["Beta_rho1_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta1 -- Random-walk
    if( RhoConfig["Beta1"]==2){
      Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho1_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta1 -- Constant over time for each category
    if( RhoConfig["Beta1"]==3){
      Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["logsigmaB1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["beta1_ct"]] = factor( 1:DataList$n_c %o% rep(1,DataList$n_t) )
    }
    # Beta2 -- Fixed (0) or Beta_rho2 mirroring Beta_rho1 (6)
    if( RhoConfig["Beta2"] %in% c(0,6) ){
      Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["logsigmaB2_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta2 -- White-noise
    if( RhoConfig["Beta2"]==1){
      Map[["Beta_rho2_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta2 -- Random-walk
    if( RhoConfig["Beta2"]==2){
      Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho2_c"]] = factor( rep(NA,DataList$n_c) )
    }
    # Beta2 -- Constant over time for each category
    if( RhoConfig["Beta2"]==3){
      Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["logsigmaB2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["beta2_ct"]] = factor( 1:DataList$n_c %o% rep(1,DataList$n_t) )
    }
    # Warnings
    if( DataList$n_c >= 2 ){
      warnings( "This version of VAST has different hyperparameters for each category. Default behavior for CPP version <=5.3.0 was to have the same hyperparameters for the intercepts of all categories." )
    }
  }
  # Hyperparameters for intercepts for >= V7.0.0
  if( all(c("L_beta1_z","L_beta2_z") %in% names(TmbParams)) ){
    if( RhoConfig["Beta1"]==0){
      Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho1_f"]] = factor( rep(NA,nrow(TmbParams$beta1_ft)) )
      Map[["L_beta1_z"]] = factor( rep(NA,length(TmbParams$L_beta1_z)) ) # Turn off all because Data_Fn has thrown an error whenever not using IID
    }
    # Beta1 -- White-noise
    if( RhoConfig["Beta1"]==1){
      Map[["Beta_rho1_f"]] = factor( rep(NA,nrow(TmbParams$beta1_ft)) )
    }
    # Beta1 -- Random-walk
    if( RhoConfig["Beta1"]==2){
      # Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) ) # Estimate Beta_mean1_c given RW, because RW in year t=0 starts as deviation from Beta_mean1_c
      Map[["Beta_rho1_f"]] = factor( rep(NA,nrow(TmbParams$beta1_ft)) )
      warnings( "Version >=7.0.0 has different behavior for random-walk intercepts than <7.0.0, so results may not be identical. Consult James Thorson or code for details.")
    }
    # Beta1 -- Constant over time for each category
    if( RhoConfig["Beta1"]==3){
      Map[["Beta_mean1_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho1_f"]] = factor( rep(NA,nrow(TmbParams$beta1_ft)) )
      Map[["beta1_ft"]] = factor( row(TmbParams$beta1_ft) )
      Map[["L_beta1_z"]] = factor( rep(NA,length(TmbParams$L_beta1_z)) ) # Turn off all because Data_Fn has thrown an error whenever not using IID
    }
    # Beta2 -- Fixed (0) or Beta_rho2 mirroring Beta_rho1 (6)
    if( RhoConfig["Beta2"] %in% c(0,6) ){
      Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho2_f"]] = factor( rep(NA,nrow(TmbParams$beta2_ft)) )
      Map[["L_beta2_z"]] = factor( rep(NA,length(TmbParams$L_beta2_z)) )    # Turn off all because Data_Fn has thrown an error whenever not using IID
    }
    # Beta2 -- White-noise
    if( RhoConfig["Beta2"]==1){
      Map[["Beta_rho2_f"]] = factor( rep(NA,nrow(TmbParams$beta2_ft)) )
    }
    # Beta2 -- Random-walk
    if( RhoConfig["Beta2"]==2){
      # Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )  # Estimate Beta_mean2_c given RW, because RW in year t=0 starts as deviation from Beta_mean2_c
      Map[["Beta_rho2_f"]] = factor( rep(NA,nrow(TmbParams$beta2_ft)) )
      warnings( "Version >=7.0.0 has different behavior for random-walk intercepts than <7.0.0, so results may not be identical. Consult James Thorson or code for details.")
    }
    # Beta2 -- Constant over time for each category
    if( RhoConfig["Beta2"]==3){
      Map[["Beta_mean2_c"]] = factor( rep(NA,DataList$n_c) )
      Map[["Beta_rho2_f"]] = factor( rep(NA,nrow(TmbParams$beta2_ft)) )
      Map[["beta2_ft"]] = factor( row(TmbParams$beta2_ft) )
      Map[["L_beta2_z"]] = factor( rep(NA,length(TmbParams$L_beta2_z)) ) # Turn off all because Data_Fn has thrown an error whenever not using IID
    }
    # Warnings
    if( DataList$n_c >= 2 ){
      warnings( "This version of VAST has different hyperparameters for each category. Default behavior for CPP version <=5.3.0 was to have the same hyperparameters for the intercepts of all categories." )
    }
  }
  if( all(c("Beta_mean1_t","Beta_mean2_t") %in% names(TmbParams)) ){
    Map[["Beta_mean1_t"]] = factor( rep(NA,DataList$n_t) )
    Map[["Beta_mean2_t"]] = factor( rep(NA,DataList$n_t) )
  }

  # Return
  return(Map)
}

