! ============================================================================
!  File:        geoclaw_mod
! ============================================================================
!    Copyright (C) 2010-04-21 Clawpack Developers http://www.clawpack.org
!
!  Distributed under the terms of the Berkeley Software Distribution (BSD)
!  license
!                     http://www.opensource.org/licenses/
! ============================================================================

module geoclaw_module

    implicit none
    save
    
    ! ========================================================================
    !  Constants
    ! ========================================================================
    integer, parameter :: GEO_PARM_UNIT = 78
    integer, parameter :: KAPPA_UNIT = 42
    real(kind=8), parameter :: pi = 4.d0*datan(1.d0)
    real(kind=8), parameter :: DEG2RAD = pi / 180.d0
    real(kind=8), parameter :: RAD2DEG = 180.d0 / pi
    
    ! ========================================================================
    !  Physics
    ! ========================================================================
    real(kind=8) :: grav, earth_radius
    integer :: coordinate_system

    ! Rotational velocity of Earth
    real(kind=8), parameter :: omega = 2.0d0 * pi / 86164.2d0
    
    ! Forcing
    logical :: coriolis_forcing ! True then coriolis terms included in src
    real(kind=8) :: theta_0 ! Used if using the beta-plane approximation
    logical :: friction_forcing ! Friction forcing will be applied
    real(kind=8) :: wet_manning_coefficient, dry_manning_coefficient
    real(kind=8) :: friction_depth
    integer, parameter :: friction_index = 4 ! Location in aux of friction
                                             ! coefficients
    
    ! Method parameters    
    real(kind=8), allocatable :: dry_tolerance(:)
    logical :: varRefTime = .FALSE. ! Choose dt refinement automatically
    
    ! ========================================================================
    !  Multi-layer
    ! ========================================================================
    integer :: num_layers
    real(kind=8), allocatable :: rho(:)
    real(kind=8), allocatable :: eta_init(:)
    
    ! Multilayer method Parameters
    integer :: eigen_method,inundation_method

    ! Loss of hyperbolicity
    logical :: check_richardson
    real(kind=8) :: richardson_tolerance

contains

    ! ========================================================================
    !  set_geo(fname)
    ! ========================================================================
    !  Reads in user parameters from the given file name if provided
    ! ========================================================================
    subroutine set_geo(file_name)

        use amr_module, only: mcapa, rinfinity
        implicit none

        ! Input
        character(len=*), intent(in), optional :: file_name

        ! Locals
        integer, parameter :: unit = 127

        open(unit=GEO_PARM_UNIT,file='fort.geo',status="unknown",action="write")

        write(GEO_PARM_UNIT,*) ' '
        write(GEO_PARM_UNIT,*) '--------------------------------------------'
        write(GEO_PARM_UNIT,*) 'Physics Parameters:'
        write(GEO_PARM_UNIT,*) '-------------------'

        ! Read user parameters from setgeo.data
        if (present(file_name)) then
            call opendatafile(unit, file_name)
        else
            call opendatafile(unit, 'physics.data')
        endif

        read(unit,*) grav
        read(unit,*) earth_radius
        read(unit,*) coordinate_system
        read(unit,*)
        read(unit,*) num_layers
        allocate(rho(num_layers),eta_init(num_layers),dry_tolerance(num_layers))
        read(unit,*) rho
        read(unit,*) eta_init
        read(unit,*)
        read(unit,*) coriolis_forcing
        if (coordinate_system == 1 .and. coriolis_forcing) then
            read(unit,*) theta_0
        else
            theta_0 = 0.d0
        endif
        read(unit,*) friction_forcing
        if (friction_forcing) then
            read(unit,*) wet_manning_coefficient
            read(unit,*) dry_manning_coefficient
            read(unit,*) friction_depth
        else
            wet_manning_coefficient = 0.d0
            dry_manning_coefficient = 0.d0
            friction_depth = rinfinity
        endif
        read(unit,*)
        read(unit,*) dry_tolerance
        read(unit,*) varRefTime
        
        close(unit)

        ! coordinate_system = 1 means Cartesian grid in meters
        ! coordinate_system = 2 means lat-long grid on sphere
        ! Check that coordinate_system is consistent with mcapa:
        if ((coordinate_system > 1) .and. (mcapa == 0)) then
            print *, 'ERROR in setgeo:  if coordinate_system > 1 then'
            print *, '      mcapa should be nonzero'
            stop
        endif
        if ((coordinate_system == 1) .and. (mcapa > 0)) then
            print *, 'ERROR in setgeo:  if coordinate_system = 1 then'
            print *, '      mcapa should be zero'
            stop
        endif

        write(GEO_PARM_UNIT,*) '   gravity:',grav
        write(GEO_PARM_UNIT,*) '   earth_radius:',earth_radius
        write(GEO_PARM_UNIT,*) '   coordinate_system:',coordinate_system
        write(GEO_PARM_UNIT,*) ' '
        write(GEO_PARM_UNIT,*) '   num_layers:',num_layers
        write(GEO_PARM_UNIT,*) '   rho:',rho
        write(GEO_PARM_UNIT,*) '   eta_init:',eta_init
        write(GEO_PARM_UNIT,*) ' '
        write(GEO_PARM_UNIT,*) '   coriolis_forcing:',coriolis_forcing
        write(GEO_PARM_UNIT,*) '   theta_0:',theta_0
        write(GEO_PARM_UNIT,*) '   friction_forcing:',friction_forcing
        write(GEO_PARM_UNIT,*) '   manning_coefficients:', &
                                wet_manning_coefficient, dry_manning_coefficient
        write(GEO_PARM_UNIT,*) '   friction_depth:',friction_depth
        write(GEO_PARM_UNIT,*) ' '
        write(GEO_PARM_UNIT,*) '   dry_tolerance:',dry_tolerance
        write(GEO_PARM_UNIT,*) '   Variable dt Refinement Ratios:',varRefTime

    end subroutine set_geo

    ! ========================================================================
    !  read_multilayer_data(file_name)
    ! ========================================================================
    subroutine read_multilayer_data(file_name)

        implicit none
        
        ! Arguments
        character(len=*), optional, intent(in) :: file_name
        
        ! Locals
        integer, parameter :: unit = 124
        integer :: ios

        ! Only read in this data if we are doing multilayer swe
        if (num_layers > 1) then
            write(GEO_PARM_UNIT,*) ' '
            write(GEO_PARM_UNIT,*) '--------------------------------------------'
            write(GEO_PARM_UNIT,*) 'Multilayer Parameters:'
            write(GEO_PARM_UNIT,*) '----------------------'

            if (present(file_name)) then
                call opendatafile(unit, file_name)
            else
                call opendatafile(unit, 'multilayer.data')
            endif

            read(unit,*) check_richardson
            read(unit,"(d16.8)") richardson_tolerance
            read(unit,"(i1)") eigen_method
            read(unit,"(i1)") inundation_method
            close(unit) 

            ! Open Kappa output file if num_layers > 1
            ! Open file for writing hyperbolicity warnings if multiple layers
            if (num_layers > 1 .and. check_richardson) then
                open(unit=KAPPA_UNIT, file='fort.kappa', iostat=ios, &
                        status="unknown", action="write")
                if ( ios /= 0 ) stop "Error opening file name fort.kappa"
            endif

            write(GEO_PARM_UNIT,*) '   check_richardson:',check_richardson
            write(GEO_PARM_UNIT,*) '   richardson_tolerance:',richardson_tolerance
            write(GEO_PARM_UNIT,*) '   eigen_method:',eigen_method
            write(GEO_PARM_UNIT,*) '   inundation_method:',inundation_method
        endif
        close(GEO_PARM_UNIT)
        
    end subroutine read_multilayer_data

    ! ==========================================================================
    !  Calculate the coriolis constant f
    !   If coordinate_system == 1 then
    !       A beta-plane approximation is used and y should be in meters
    !   if coordinate_system == 2 then
    !       Grid is in lat-long and y should be in degrees which is converted
    !       to radians
    ! ==========================================================================
    real(kind=8) pure function coriolis(y)

        implicit none
        
        ! Input
        real(kind=8), intent(in) :: y
        
        ! Locals
        real(kind=8) :: theta
        
        ! Assume beta plane approximation and y is in meters    
        if (coordinate_system == 1) then
            theta = y / 111d3 * DEG2RAD + theta_0
            coriolis = 2.d0 * omega * (sin(theta_0) + (theta - theta_0)     &
                                                    * cos(theta_0))
        else if (coordinate_system == 2) then        
            coriolis = 2.d0 * omega * sin(y * DEG2RAD)
        else
            ! Unknown coordinate system, return nothing
            coriolis = 0.d0
        endif
    end function coriolis

    ! ==========================================================================
    !  Calculate the distance along a sphere
    !    real(kind=8) spherical_distance(x1,x2)
    !       x1 = (long,lat)
    !       x2 = (long,lat)
    ! ==========================================================================
    real(kind=8) pure function spherical_distance(x1,y1,x2,y2) result(distance)

        implicit none

        ! Input
        real(kind=8), intent(in) :: x1,y1,x2,y2

        ! Locals
        real(kind=8) :: dx ,dy

        dx = (x2 - x1) * DEG2RAD
        dy = (y2 - y1) * DEG2RAD

        distance = earth_radius * 2.d0 * asin(sqrt(sin(0.5d0*dy)**2 &
                                   + cos(y1 * DEG2RAD)*cos(y2 * DEG2RAD) &
                                   * sin(0.5d0*dx)**2))

    end function spherical_distance

    !=================================================================
    ! Transform long,lat --> (x,y) coordinates.
    !
    ! On input:
    !    coords(2) = (longitude (E/W),latitude (N/S))
    !    projection_center(2) = (longitude (E/W),latitude (N/S)) - coordinates 
    !                        where projection is true
    !
    ! On output:
    !    x(2)          (meters)
    !=================================================================
    pure function latlon2xy(coords,projection_center) result(x)

        real(kind=8), intent(in) :: coords(2), projection_center(2)
        real(kind=8) :: x(2)

        x(1) = deg2rad * earth_radius * (coords(1) - &
                    projection_center(1)) * cos(deg2rad * projection_center(2))
        x(2) = deg2rad * earth_radius * coords(2)

    end function latlon2xy

    !=================================================================
    ! Transform (x,y) --> (lat,lon) coordinates.
    !
    ! On input:
    !    x(2) = (meters)          
    !    projection_center(2) = (longitude (E/W),latitude (N/S)) - coordinates 
    !                        where projection is true
    !
    ! On output:
    !    coords(2) = (longitude,latitude)
    !=================================================================
    pure function xy2latlon(x,projection_center) result(coords)

        real(kind=8), intent(in) :: x(2), projection_center(2)
        real(kind=8) :: coords(2)

        coords(1) = projection_center(1) + x(1) &
                / (deg2rad * earth_radius * cos(deg2rad * projection_center(2)))
        coords(2) = x(2) / (deg2rad * earth_radius)
    end function xy2latlon

end module geoclaw_module
