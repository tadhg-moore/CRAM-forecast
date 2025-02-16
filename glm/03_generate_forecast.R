#### Move to 03_forecast_inflows.R
# remotes::install_github("tadhg-moore/flare-1")
# remotes::install_github("aemon-j/GLM3r", ref = "v3.1.1") # Needed for Windows

forecast_location <- file.path(getwd(), "glm")
noaa_data_location <- file.path(getwd(),"data","NOAA_data","noaa","NOAAGEFS_1hr")


config <- yaml::read_yaml(file.path(forecast_location, "configuration_files","configure_flare.yml"))
run_config <- yaml::read_yaml(file.path(forecast_location, "configuration_files","run_configuration.yml"))

config$run_config <- run_config
config$run_config$forecast_location <- forecast_location

# Set up timings
start_datetime_local <- lubridate::as_datetime(paste0(config$run_config$start_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
if(is.na(config$run_config$forecast_start_day_local)){
  end_datetime_local <- lubridate::as_datetime(paste0(config$run_config$end_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
  forecast_start_datetime_local <- end_datetime_local
}else{
  forecast_start_datetime_local <- lubridate::as_datetime(paste0(config$run_config$forecast_start_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
  end_datetime_local <- forecast_start_datetime_local + lubridate::days(config$run_config$forecast_horizon)
}

#Weather Drivers
start_datetime_UTC <-  lubridate::with_tz(start_datetime_local, tzone = "CST6CDT")
end_datetime_UTC <-  lubridate::with_tz(end_datetime_local, tzone = "CST6CDT")
forecast_start_datetime_CT <- lubridate::with_tz(forecast_start_datetime_local, tzone = "CST6CDT")
forecast_start_datetime_UTC <- lubridate::with_tz(forecast_start_datetime_local, tzone = "UTC")
forecast_hour <- lubridate::hour(forecast_start_datetime_CT)
if(forecast_hour < 10){forecast_hour <- paste0("0",forecast_hour)}
noaa_forecast_path <- file.path(noaa_data_location,config$lake_name_code, lubridate::as_date(forecast_start_datetime_UTC),forecast_hour)


forecast_files <- list.files(noaa_forecast_path, full.names = TRUE)

if(length(forecast_files) > 0){
  
  ##### Read configuration files
  config <- yaml::read_yaml(file.path(forecast_location, "configuration_files","configure_flare.yml"))
  run_config <- yaml::read_yaml(file.path(forecast_location, "configuration_files","run_configuration.yml"))
  
  config$run_config <- run_config
  config$run_config$forecast_location <- forecast_location
  
  if(!dir.exists(config$run_config$execute_location)){
    dir.create(config$run_config$execute_location)
  }
  
  pars_config <- readr::read_csv(file.path(config$run_config$forecast_location, "configuration_files", config$par_file), col_types = readr::cols())
  obs_config <- readr::read_csv(file.path(config$run_config$forecast_location, "configuration_files", config$obs_config_file), col_types = readr::cols())
  states_config <- readr::read_csv(file.path(config$run_config$forecast_location, "configuration_files", config$states_config_file), col_types = readr::cols())
  
  # Set up timings
  start_datetime_local <- lubridate::as_datetime(paste0(config$run_config$start_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
  if(is.na(config$run_config$forecast_start_day_local)){
    end_datetime_local <- lubridate::as_datetime(paste0(config$run_config$end_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
    forecast_start_datetime_local <- end_datetime_local
  }else{
    forecast_start_datetime_local <- lubridate::as_datetime(paste0(config$run_config$forecast_start_day_local," ",config$run_config$start_time_local), tz = config$local_tzone)
    end_datetime_local <- forecast_start_datetime_local + lubridate::days(config$run_config$forecast_horizon)
  }
  
  
  #Download and process observations (already done)
  
  cleaned_observations_file_long <- file.path(config$qaqc_data_location,"observations_postQAQC_long.csv")
  observed_met_file <- file.path(config$qaqc_data_location,"observed-met_cram.nc")
  
  #Step up Drivers
  
  #Weather Drivers
  start_datetime_UTC <-  lubridate::with_tz(start_datetime_local, tzone = "CST6CDT")
  end_datetime_UTC <-  lubridate::with_tz(end_datetime_local, tzone = "CST6CDT")
  forecast_start_datetime_CT <- lubridate::with_tz(forecast_start_datetime_local, tzone = "CST6CDT")
  forecast_hour <- lubridate::hour(forecast_start_datetime_CT)
  if(forecast_hour < 10){forecast_hour <- paste0("0",forecast_hour)}
  forecast_path <- file.path(config$data_location, "NOAA_data/noaa/NOAAGEFS_1hr",config$lake_name_code,lubridate::as_date(forecast_start_datetime_UTC),forecast_hour)
  
  met_out <- flare::generate_glm_met_files(obs_met_file = observed_met_file,
                                           out_dir = config$run_config$execute_location,
                                           forecast_dir = forecast_path,
                                           local_tzone = config$local_tzone,
                                           start_datetime_local = start_datetime_local,
                                           end_datetime_local = end_datetime_local,
                                           forecast_start_datetime = forecast_start_datetime_local,
                                           use_forecasted_met = TRUE)
  met_file_names <- met_out$filenames
  historical_met_error <- met_out$historical_met_error
  
  
  #Create observation matrix
  obs <- flare::create_obs_matrix(cleaned_observations_file_long,
                                  obs_config,
                                  start_datetime_local,
                                  end_datetime_local,
                                  local_tzone = config$local_tzone,
                                  modeled_depths = config$modeled_depths)
  
  #Set observations in the "future" to NA
  full_time_forecast <- seq(start_datetime_local, end_datetime_local, by = "1 day")
  obs[ , which(full_time_forecast > forecast_start_datetime_local), ] <- NA
  
  
  states_config <- flare::generate_states_to_obs_mapping(states_config, obs_config)
  
  model_sd <- flare::initiate_model_error(config, states_config, forecast_location)
  
  #Set inital conditions
  if(is.na(run_config$restart_file)){
    init <- flare::generate_initial_conditions(states_config,
                                               obs_config,
                                               pars_config,
                                               obs,
                                               config)
  }else{
    
    nc <- ncdf4::nc_open(run_config$restart_file)
    forecast <- ncdf4::ncvar_get(nc, "forecast")
    if(historical_met_error){
      restart_index <- max(which(forecast == 0)) + 1
    }else{
      restart_index <- max(which(forecast == 0))
    }
    if(max(which(forecast == 0)) == length(forecast)){
      restart_index <- max(which(forecast == 0))
    }
    
    init <- flare::generate_restart_initial_conditions(
      restart_file = run_config$restart_file,
      state_names = states_config$state_names,
      par_names = pars_config$par_names_save,
      restart_index = restart_index)
  }
  
  aux_states_init <- list()
  aux_states_init$snow_ice_thickness <- init$snow_ice_thickness
  aux_states_init$avg_surf_temp <- init$avg_surf_temp
  aux_states_init$the_sals_init <- config$the_sals_init
  aux_states_init$mixing_vars <- init$mixing_vars
  aux_states_init$model_internal_depths <- init$model_internal_depths
  aux_states_init$lake_depth <- init$lake_depth
  aux_states_init$salt <- init$salt
  
  # states_init = init$states
  # pars_init = init$pars
  # aux_states_init = aux_states_init
  # obs = obs
  # obs_sd = obs_config$obs_sd
  # model_sd = model_sd
  # working_directory = config$run_config$execute_location
  # met_file_names = met_file_names
  # inflow_file_names = NA
  # outflow_file_names = NA
  # start_datetime = start_datetime_local
  # end_datetime = end_datetime_local
  # forecast_start_datetime = forecast_start_datetime_local
  # config = config
  # pars_config = pars_config
  # states_config = states_config
  # obs_config = obs_config
  # management = NULL
  
  #Run EnKF
  enkf_output <- flare::run_enkf_forecast(states_init = init$states,
                                          pars_init = init$pars,
                                          aux_states_init = aux_states_init,
                                          obs = obs,
                                          obs_sd = obs_config$obs_sd,
                                          model_sd = model_sd,
                                          working_directory = config$run_config$execute_location,
                                          met_file_names = met_file_names,
                                          inflow_file_names = NULL,
                                          outflow_file_names = NULL,
                                          start_datetime = start_datetime_local,
                                          end_datetime = end_datetime_local,
                                          forecast_start_datetime = forecast_start_datetime_local,
                                          config = config,
                                          pars_config = pars_config,
                                          states_config = states_config,
                                          obs_config = obs_config, 
                                          management = NULL
                                          
  )
  
  # Save forecast
  saved_file <- flare::write_forecast_netcdf(enkf_output,
                                             forecast_location = config$run_config$forecast_location)
  
  #Create EML Metadata
  flare::create_flare_eml(file_name = saved_file,
                          enkf_output)
  
  flare::plotting_general(saved_file, qaqc_location = config$qaqc_data_location)
  
  unlist(config$run_config$execute_location, recursive = TRUE)
  
  
  run_config$start_day_local <- run_config$forecast_start_day_local
  run_config$forecast_start_day_local <- as.character(lubridate::as_date(run_config$forecast_start_day_local) + lubridate::days(1))
  run_config$restart_file <- NA #saved_file
  yaml::write_yaml(run_config, file = file.path(forecast_location, "configuration_files","run_configuration.yml"))
}else{
  run_config$forecast_start_day_local <- as.character(lubridate::as_date(run_config$forecast_start_day_local) + lubridate::days(1))
  yaml::write_yaml(run_config, file = file.path(forecast_location, "configuration_files","run_configuration.yml"))
}
 
