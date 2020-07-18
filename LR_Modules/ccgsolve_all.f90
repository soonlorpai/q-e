!
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!----------------------------------------------------------------------
subroutine ccgsolve_all (ch_psi, ccg_psi, e, d0psi, dpsi, h_diag, &
     ndmx, ndim, ethr, ik, kter, conv_root, anorm, nbnd, npol, freq_c)
  !----------------------------------------------------------------------
  !
  !     iterative solution of the linear systems (i=1,nbnd):
  !
  !                 ( H - e_i + Q ) * dpsi_i = d0psi_i                      (1)
  !
  !     where H is a complex hermitean matrix, e_i is a real scalar, Q is a
  !     projector on occupied states, dpsi_i and d0psi_ are complex vectors
  !
  !     on input:
  !                 ch_psi   EXTERNAL  name of a subroutine:
  !                          Calculates  (H-e+Q)*psi products.
  !                          Vectors psi and psip should be dimensioned
  !                          (ndmx,nbnd)
  !
  !                 cg_psi   EXTERNAL  name of a subroutine:
  !                          which calculates (h-e)^-1 * psi, with
  !                          some approximation, e.g. (diag(h)-e)
  !
  !                 e        real     unperturbed eigenvalue.
  !
  !                 dpsi     contains an estimate of the solution
  !                          vector.
  !
  !                 d0psi    contains the right hand side vector
  !                          of the system.
  !
  !                 ndmx     integer row dimension of dpsi, ecc.
  !
  !                 ndim     integer actual row dimension of dpsi
  !
  !                 ethr     real     convergence threshold. solution
  !                          improvement is stopped when the error in
  !                          eq (1), defined as l.h.s. - r.h.s., becomes
  !                          less than ethr in norm.
  !
  !     on output:  dpsi     contains the refined estimate of the
  !                          solution vector.
  !
  !                 d0psi    is corrupted on exit
  !
  !   revised (extensively)       6 Apr 1997 by A. Dal Corso & F. Mauri
  !   revised (to reduce memory) 29 May 2004 by S. de Gironcoli
  !
  USE kinds,          ONLY : DP
  USE mp_bands,       ONLY : intra_bgrp_comm, inter_bgrp_comm, use_bgrp_in_hpsi
  USE mp,             ONLY : mp_sum, mp_barrier
  USE control_flags,  ONLY : gamma_only
  USE gvect,          ONLY : gstart

  implicit none
  !
  !   first the I/O variables
  !
  integer :: ndmx, & ! input: the maximum dimension of the vectors
             ndim, & ! input: the actual dimension of the vectors
             kter, & ! output: counter on iterations
             nbnd, & ! input: the number of bands
             npol, & ! input: number of components of the wavefunctions
             ik      ! input: the k point

  real(DP) :: &
             e(nbnd), & ! input: the actual eigenvalue
             anorm,   & ! output: the norm of the error in the solution
             ethr       ! input: the required precision

  complex(DP) :: &
             dpsi (ndmx*npol, nbnd), & ! output: the solution of the linear syst
             h_diag(ndmx*npol,nbnd), & ! input: an estimate of ( H - \epsilon -w)
                                       ! w is complex
             freq_c                , & ! complex frequency
             d0psi (ndmx*npol, nbnd)   ! input: the known term

  logical :: conv_root ! output: if true the root is converged
  external ch_psi      ! input: the routine computing ch_psi
  external ccg_psi      ! input: the routine computing cg_psi
  !
  !  here the local variables
  !
  integer, parameter :: maxter = 4000
  ! the maximum number of iterations
  integer :: iter, ibnd, ibnd_, lbnd
  ! counters on iteration, bands
  integer , allocatable :: conv (:)
  ! if 1 the root is converged

  complex(DP), allocatable :: g (:,:),  t (:,:),  h (:,:),  hold (:,:)
  COMPLEX(DP), ALLOCATABLE :: gs (:,:), ts (:,:), hs (:,:), hsold (:,:)
  !  the gradient of psi
  !  the preconditioned gradient
  !  the delta gradient
  !  the conjugate gradient
  !  work space
  complex(DP) ::  dcgamma, dcgamma1, dclambda, dclambda1
  !  the ratio between rho
  !  step length
  complex(DP), external :: zdotc
  REAL(kind=dp), EXTERNAL :: ddot
  !  the scalar product
  real(DP), allocatable    :: eu (:)
  complex(DP), allocatable :: rho (:), rhoold (:), euc (:), a(:), c(:)
  ! the residue
  ! auxiliary for h_diag
  real(DP) :: kter_eff
  ! account the number of iterations with b
  ! coefficient of quadratic form
  integer, allocatable :: indb(:)
  
  ! bgrp parallelization auxiliary variables
  INTEGER :: n_start, n_end, my_nbnd
  logical :: lsave_use_bgrp_in_hpsi
  !
  call start_clock ('ccgsolve')

  call divide (inter_bgrp_comm,nbnd,n_start,n_end)
!  my_nbnd = n_end - n_start + 1
  my_nbnd =nbnd

  ! allocate workspace (bgrp distributed)
  allocate ( conv(nbnd) )
  allocate ( g(ndmx*npol,my_nbnd), t(ndmx*npol,my_nbnd), h(ndmx*npol,my_nbnd), &
             hold(ndmx*npol,my_nbnd) )
  allocate ( gs(ndmx*npol,my_nbnd), ts(ndmx*npol,my_nbnd), hs(ndmx*npol,my_nbnd), &
             hsold(ndmx*npol,my_nbnd) )
  allocate ( a(my_nbnd), c(my_nbnd) )
  allocate ( rho(my_nbnd), rhoold(my_nbnd) )
  allocate ( eu(my_nbnd) )
  allocate ( euc(my_nbnd) )
  allocate ( indb(my_nbnd) )
  !      WRITE( stdout,*) g,t,h,hold

  kter_eff = 0.d0 ; conv (1:nbnd) = 0

  g=(0.d0,0.d0); t=(0.d0,0.d0); h=(0.d0,0.d0); hold=(0.d0,0.d0)
  gs=(0.d0,0.d0); ts=(0.d0,0.d0); hs=(0.d0,0.d0); hsold=(0.d0,0.d0)

  rho= (0.0d0, 0.0d0); rhoold=(0.0d0,0.d0)

  ! bgrp parallelization is done outside h_psi/s_psi. set use_bgrp_in_hpsi temporarily to false
  lsave_use_bgrp_in_hpsi = use_bgrp_in_hpsi ; use_bgrp_in_hpsi = .false.

  do ibnd = 1, nbnd
     indb(ibnd) = ibnd
  enddo

  eu = e
  do iter = 1, maxter
     !
     !    compute the gradient. can reuse information from previous step
     !
     if (iter == 1) then
        do ibnd = n_start, n_end
!        do ibnd =1, nbnd
           euc(ibnd) = CMPLX(e(indb(ibnd))+DREAL(freq_c), DIMAG(freq_c), KIND=DP)
        ENDDO

        call ch_psi (ndim, dpsi, g, euc, ik, my_nbnd)

        do ibnd = n_start, n_end ; ibnd_ = ibnd - n_start + 1
!        do ibnd =1, nbnd
           call zaxpy (ndim, (-1.d0,0.d0), d0psi(1,ibnd), 1, g(1,ibnd_), 1)
!           call zaxpy (ndmx, (-1.d0,0.d0), d0psi(1,ibnd), 1, g(1,ibnd), 1)
        enddo
        IF (npol==2) THEN
           do ibnd = n_start, n_end ; ibnd_ = ibnd - n_start + 1
!           do ibnd = 1, nbnd
              call zaxpy (ndim, (-1.d0,0.d0), d0psi(ndmx+1,ibnd), 1, g(ndmx+1,ibnd_), 1)
!              call zaxpy (ndim, (-1.d0,0.d0), d0psi(ndmx+1,ibnd), 1, g(ndmx+1,ibnd), 1)
           enddo
        END IF
        gs(:,:) = CONJG(g(:,:))
     endif
     !
     !    compute preconditioned residual vector and convergence check
     !
     lbnd = 0
     do ibnd = n_start, n_end ;  ibnd_ = ibnd - n_start + 1
!     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd = lbnd+1
           call zcopy (ndmx*npol, g (1, ibnd_), 1, h (1, ibnd_), 1)
           call zcopy (ndmx*npol, gs (1, ibnd_), 1, hs (1, ibnd_), 1)
!           call zcopy (ndmx, g (1, ibnd), 1, h (1, ibnd), 1)
!           call zcopy (ndmx, gs (1, ibnd), 1, hs (1, ibnd), 1)

           call ccg_psi(ndmx, ndim, 1, h(1,ibnd_), h_diag(1,ibnd), 1 )
           call ccg_psi(ndmx, ndim, 1, hs(1,ibnd_), h_diag(1,ibnd), -1 )

!           call ccg_psi(ndmx, ndim, 1, h(1,ibnd), h_diag(1,ibnd), 1 )
!           call ccg_psi(ndmx, ndim, 1, hs(1,ibnd), h_diag(1,ibnd), -1 )
           
           IF (gamma_only) THEN
              rho(lbnd)=2.0d0*ddot(2*ndmx*npol,h(1,ibnd_),1,g(1,ibnd_),1)
!              rho(lbnd)=2.0d0*ddot(2*ndmx*npol,h(1,ibnd),1,g(1,ibnd),1)
              IF(gstart==2) THEN
                 rho(lbnd)=rho(lbnd)-DBLE(h(1,ibnd_))*DBLE(g(1,ibnd_))
!                 rho(lbnd)=rho(lbnd)-DBLE(h(1,ibnd))*DBLE(g(1,ibnd))
              ENDIF
           ELSE
              rho(lbnd) = zdotc (ndim, hs(1,ibnd_), 1, g(1,ibnd_), 1)
!              rho(lbnd) = zdotc (ndmx, hs(1,ibnd), 1, g(1,ibnd), 1)
           ENDIF

        endif
     enddo
     kter_eff = kter_eff + DBLE (lbnd) / DBLE (nbnd)
     call mp_sum( rho(1:lbnd), intra_bgrp_comm )
     do ibnd = n_end, n_start, -1 ; ibnd_ = ibnd - n_start + 1
!     do ibnd = nbnd, 1, -1
        if (conv(ibnd).eq.0) then
           rho(ibnd_)=rho(lbnd)
!           rho(ibnd)=rho(lbnd)
           lbnd = lbnd -1
           anorm = sqrt ( abs (rho (ibnd_)) )
!           anorm = sqrt ( abs (rho (ibnd)) )
           if (anorm.lt.ethr) conv (ibnd) = 1
        endif
     enddo
!
     conv_root = .true.
     do ibnd = n_start, n_end
!     do ibnd = 1, nbnd
        conv_root = conv_root.and. (conv (ibnd) .eq.1)
     enddo
     if (conv_root) goto 100
     !
     !        compute the step direction h. Conjugate it to previous step
     !
     lbnd = 0
     do ibnd = n_start, n_end ; ibnd_ = ibnd - n_start + 1
!     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
!
!          change sign to h and hs
!
           call dscal (2 * ndmx * npol, - 1.d0, h (1, ibnd_), 1)
           call dscal (2 * ndmx * npol, - 1.d0, hs (1, ibnd_), 1)
!           call dscal (2 * ndmx , - 1.d0, h (1, ibnd), 1)
!           call dscal (2 * ndmx , - 1.d0, hs (1, ibnd), 1)

           if (iter.ne.1) then
              dcgamma = rho (ibnd_) / rhoold (ibnd_)
!              dcgamma = rho (ibnd) / rhoold (ibnd)
              dcgamma1 = CONJG(dcgamma)

              call zaxpy (ndmx*npol, dcgamma, hold (1, ibnd_), 1, h (1, ibnd_), 1)
              CALL zaxpy (ndmx*npol, dcgamma1, hsold (1, ibnd_), 1, hs (1, ibnd_), 1)

!              call zaxpy (ndmx, dcgamma, hold (1, ibnd), 1, h (1, ibnd),1)
!              CALL zaxpy (ndmx, dcgamma1, hsold (1, ibnd), 1, hs (1, ibnd), 1)
           endif

!
! here hold is used as auxiliary vector in order to efficiently compute t = A*h
! it is later set to the current (becoming old) value of h
!
           lbnd = lbnd+1
           call zcopy (ndmx*npol, h (1, ibnd_), 1, hold (1, lbnd), 1)
           CALL zcopy (ndmx*npol, hs (1, ibnd_), 1, hsold (1, lbnd), 1)
!           call zcopy (ndmx, h (1, ibnd), 1, hold (1, lbnd), 1)
!           CALL zcopy (ndmx, hs (1, ibnd), 1, hsold (1, lbnd), 1)

!           eu (lbnd) = e (ibnd)
           indb (lbnd) = ibnd
        endif
     enddo

     !
     !        compute t = A*h and  ts= A^+ * h 
     !

     DO ibnd=1,lbnd
        euc(ibnd) = CMPLX(e(indb(ibnd))+DREAL(freq_c), DIMAG(freq_c), KIND=DP)
     ENDDO

     call ch_psi (ndim, hold, t, euc, ik, lbnd)

!     DO ibnd=1,lbnd
!        euc(ibnd) = CMPLX(eu(ibnd)+DREAL(freq_c),-DIMAG(freq_c), KIND=DP)
!     ENDDO

     call ch_psi (ndim, hsold, ts, conjg(euc), ik, lbnd)

     !
     !        compute the coefficients a and c for the line minimization
     !        compute step length lambda
     !

     lbnd=0
     do ibnd = n_start, n_end ; ibnd_ = ibnd - n_start + 1
!     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd=lbnd+1

           IF (gamma_only) THEN
              a(lbnd) = 2.0d0*ddot(2*ndmx*npol,hs(1,ibnd_),1,g(1,ibnd_),1)
              c(lbnd) = 2.0d0*ddot(2*ndmx*npol,hs(1,ibnd_),1,t(1,lbnd),1)
!              a(lbnd) = 2.0d0*ddot(2*ndmx*npol,hs(1,ibnd),1,g(1,ibnd),1)
!              c(lbnd) = 2.0d0*ddot(2*ndmx*npol,hs(1,ibnd),1,t(1,lbnd),1)
              IF (gstart == 2) THEN
                 a(lbnd)=a(lbnd)-DBLE(hs(1,ibnd_))*DBLE(g(1,ibnd_))
                 c(lbnd)=c(lbnd)-DBLE(hs(1,ibnd_))*DBLE(t(1,lbnd))
!                 a(lbnd)=a(lbnd)-DBLE(hs(1,ibnd))*DBLE(g(1,ibnd))
!                 c(lbnd)=c(lbnd)-DBLE(hs(1,ibnd))*DBLE(t(1,lbnd))

              ENDIF
           ELSE
              a(lbnd) = zdotc (ndmx*npol, hs(1,ibnd_), 1, g(1,ibnd_), 1)
              c(lbnd) = zdotc (ndmx*npol, hs(1,ibnd_), 1, t(1,lbnd), 1)
!              a(lbnd) = zdotc (ndmx, hs(1,ibnd), 1, g(1,ibnd), 1)
!              c(lbnd) = zdotc (ndmx, hs(1,ibnd), 1, t(1,lbnd), 1)

           ENDIF


        end if
     end do

     !
     call mp_sum(  a(1:lbnd), intra_bgrp_comm )
     call mp_sum(  c(1:lbnd), intra_bgrp_comm )
     lbnd=0
     do ibnd = n_start, n_end ; ibnd_ = ibnd - n_start + 1
!     do ibnd = 1, nbnd
        if (conv (ibnd) .eq.0) then
           lbnd=lbnd+1
           dclambda = - a(lbnd) / c(lbnd)
           dclambda1 = CONJG(dclambda)
           !
           !    move to new position
           !

           call zaxpy (ndmx*npol, dclambda, h(1,ibnd_), 1, dpsi(1,ibnd), 1)
!           call zaxpy (ndmx, dclambda, h(1,ibnd), 1, dpsi(1,ibnd), 1)

           !
           !    update to get the gradient
           !
           !g=g+lam
           call zaxpy (ndmx*npol, dclambda, t(1,lbnd), 1, g(1,ibnd_), 1)
           CALL zaxpy (ndmx*npol, dclambda1, ts(1,lbnd), 1, gs(1,ibnd_), 1)

!           call zaxpy (ndmx, dclambda, t(1,lbnd), 1, g(1,ibnd), 1)
!           CALL zaxpy (ndmx, dclambda1, ts(1,lbnd), 1, gs(1,ibnd), 1)

           !
           !    save current (now old) h and rho for later use
           !
           call zcopy (ndmx*npol, h(1,ibnd_), 1, hold(1,ibnd_), 1)
           CALL zcopy (ndmx*npol, hs(1,ibnd_), 1, hsold(1,ibnd_), 1)

!           call zcopy (ndmx, h(1,ibnd), 1, hold(1,ibnd), 1)
!           CALL zcopy (ndmx, hs(1,ibnd), 1, hsold(1,ibnd), 1)

           rhoold (ibnd_) = rho (ibnd_)
!           rhoold (ibnd) = rho (ibnd)


        endif
     enddo
  enddo

100 continue
  ! deallocate workspace not needed anymore
  deallocate (eu) ; deallocate (rho, rhoold) ; deallocate (a,c) ; deallocate (g, t, h, hold)
  deallocate (euc)

  ! wait for all bgrp to complete their task
  CALL mp_barrier( inter_bgrp_comm )

  ! check if all root converged across all bgrp
  call mp_sum( conv, inter_bgrp_comm )
  conv_root = .true.
  do ibnd = 1, nbnd
     conv_root = conv_root.and. (conv (ibnd) .eq.1)
  enddo
  deallocate (conv)

  ! collect the result
  if (n_start > 1 ) dpsi(:, 1:n_start-1) = (0.d0,0.d0) ; if (n_end < nbnd) dpsi(:, n_end+1:nbnd) = (0.d0,0.d0)
  call mp_sum( dpsi, inter_bgrp_comm )

  call mp_sum( kter_eff, inter_bgrp_comm )
  kter = kter_eff

  ! restore the value of use_bgrp_in_hpsi to its saved value
  use_bgrp_in_hpsi = lsave_use_bgrp_in_hpsi


  call stop_clock ('ccgsolve')
  return
end subroutine ccgsolve_all