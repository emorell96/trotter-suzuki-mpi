#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.61])
AC_INIT([trotter-suzuki], [1.1])
m4_include([m4/ax_mpi_options.m4])
m4_include([m4/ax_mpi_tests.m4])
AC_CONFIG_SRCDIR([src/trottertest.cpp])
AC_CONFIG_HEADERS([config.h])

# Checks for programs.
CXXFLAGS="-fPIC"
AC_PROG_CXX
AC_PROG_INSTALL

AC_OPENMP
openmp_enabled=no
if test x"$OPENMP_CFLAGS" != x"" ; then
  openmp_enabled=yes
fi
string=`$CXX --version`
# Change -fopenmp to -openmp if using ICC
if [[[ $string == *"ICC"* ]]]
then
  if test x"$OPENMP_CFLAGS" = x"-fopenmp"
  then
    OPENMP_CFLAGS=-openmp
  fi
fi

CXXFLAGS="${CXXFLAGS} ${OPENMP_CFLAGS}"

if [[[ $string == *"ICC"* ]]]
then  
  CXXFLAGS="${CXXFLAGS}"
else
  AS_IF([test "x$GXX" = "xyes"],[CXXFLAGS="${CXXFLAGS} -Ofast -march=native"])
fi

#find out what version we are running
ARCH=`uname -m`
if [[ $ARCH == "x86_64" ]];
then
  SUFFIX="64"
else
  SUFFIX=""
fi

# Setup CUDA paths
# ------------------------------------------------------------------------------
CUDA_PATH=/usr/local/cuda
AC_ARG_WITH([cuda],
   [  --with-cuda=PATH    prefix where cuda is installed [default=/usr/local/cuda]])

if test x"$with_cuda" != x"no" ; then

  if test -n "$with_cuda"
  then
     CUDA_PATH=$with_cuda
  fi

  AC_CHECK_PROG(NVCC_CHECK,nvcc,yes,no,$CUDA_PATH/bin)
  if test x"$NVCC_CHECK" = x"yes" ; then
     cuda_enabled=yes
     CUDA_CFLAGS="-I$CUDA_PATH/include -use_fast_math -Xptxas "-v" -Xcompiler \"${CXXFLAGS}\""
     CXXFLAGS="${CXXFLAGS} -I$CUDA_PATH/include"
     CUDA_LIBS="-lcudart"
     CUDA_LDFLAGS="-L$CUDA_PATH/lib$SUFFIX"
     NVCC="$CUDA_PATH/bin/nvcc"
     AC_SUBST(CUDA_CFLAGS)
     AC_SUBST(CUDA_LIBS)
     AC_SUBST(CUDA_LDFLAGS)
     AC_SUBST(NVCC)
     AC_DEFINE([CUDA], 1, [cuda enabled])
  elif test -n "$with_cuda" ; then
     echo "---------------------------------------"
     echo "Unable to find CUDA in $with_cuda."
     echo "Building a version without CUDA.    "
     echo "---------------------------------------"
     cuda_enabled=no
  else 
     cuda_enabled=no
  fi
else
  cuda_enabled=no  
fi

AM_CONDITIONAL([HAVE_CUDA], [test x"$cuda_enabled" = x"yes"])

#Setup MPI Paths
# ------------------------------------------------------------------------------
AC_ARG_WITH([mpi],
   [  --with-mpi=PATH    prefix where MPI is installed])

mpi_enabled=no
if test x"$with_mpi" = x"no" ; then	
	AC_MSG_ERROR([YOU MUST USE MPI COMPILER: Please do not give configure the option --without-mpi or --with-mpi=no])
else   
    AX_MPI_OPTIONS
    if test x"$MPI_CXX" != x"none"; then
      AX_MPI_TESTS
      CXX=$MPI_CXX
      mpi_enabled=yes
    fi
fi

#Setup CppUnit
#-------------------------------------------------------------------------------
TEST_LIBS="-lcppunit -ldl"
TEST_DEFS=-DCHECK
AC_SUBST(TEST_LIBS)
AC_SUBST(TEST_DEFS)

AC_CONFIG_FILES([Makefile
                 src/Makefile])
AC_OUTPUT

echo \
"-------------------------------------------------

 ${PACKAGE_NAME} Version ${PACKAGE_VERSION}

 Prefix: ${prefix}.
 Compiler: ${CXX} ${CXXFLAGS} ${MPI_INC} ${MPI_LIBDIR} ${MPI_LIBS}

 Package features:
   OpenMP enabled: ${openmp_enabled}
   MPI enabled: ${mpi_enabled}
   CUDA enabled: ${cuda_enabled}

 Now type 'make @<:@<target>@:>@'
   where the optional <target> is:
     all                - build all binaries
     install            - install everything

--------------------------------------------------"