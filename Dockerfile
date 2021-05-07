FROM ubuntu:20.04 as base_runtime
MAINTAINER https://github.com/longgangfan/
ENV LANG=C.UTF-8
ENV PYVER=3.8
# Setup some things in anticipation of virtualenvs
ENV VIRTUAL_ENV=/opt/venv
# The following ensures that the venv takes precedence if available
ENV PATH=${VIRTUAL_ENV}/bin:$PATH
# The following ensures venv packages are available when using system python (such as from jupyter)
ENV PYTHONPATH=${PYTHONPATH}:${VIRTUAL_ENV}/lib/python${PYVER}/site-packages

# install runtime requirements
RUN apt-get update -qq \
&&  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
        bash-completion \
        bash-completion \
        python${PYVER}-minimal \
        python3-virtualenv \
        python3-pip \
        python3-numpy \
        python3-numpy-dbg \
        vim \
        less \
        git \
	wget \
        valgrind valgrind-dbg valgrind-mpi \
        gdb cgdb \
	python3-sdl2 \
&&  apt-get clean \
&&  rm -rf /var/lib/apt/lists/*

RUN pip3 install -U setuptools  \
&&  pip3 install --no-cache-dir \
        packaging \
        appdirs \
        jupyter \
        jupytext \
        jupyterlab \
        plotly \
        matplotlib \
        pillow \
        ipython \
        ipyparallel \
        pint \
        scipy \ 
        rise \
        tabulate \
	numpy
# install petsc
FROM base_runtime AS build_base
# install build requirements
RUN apt-get update -qq 
RUN DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
        build-essential \
        cmake \
        gfortran \
        python3-dev \
        libopenblas-dev \
        libz-dev \
	libxml2 \
	libxml2-dev \
	libnuma-dev \
	libgl1-mesa-dev \
	libx11-dev \
	zlib1g-dev \
	swig \
	scons
# build mpi
WORKDIR /tmp/mpich-build
ARG MPICH_VERSION="3.4.1"
RUN wget http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz 
RUN  tar xvzf mpich-${MPICH_VERSION}.tar.gz 
WORKDIR /tmp/mpich-build/mpich-${MPICH_VERSION}              
ARG MPICH_CONFIGURE_OPTIONS="--prefix=/usr/local --with-device=ch4:ucx  --enable-g=option=none --disable-debuginfo --enable-fast=O3,ndebug --without-timing --without-mpit-pvars"
ARG MPICH_MAKE_OPTIONS="-j8"
RUN ./configure ${MPICH_CONFIGURE_OPTIONS} 
RUN make ${MPICH_MAKE_OPTIONS}             
RUN make install                           
RUN ldconfig
# create venv now for forthcoming python packages
RUN /usr/bin/python3 -m virtualenv --python=/usr/bin/python3 ${VIRTUAL_ENV} 
RUN pip3 install --no-cache-dir mpi4py
RUN pip3 install --no-cache-dir lavavu

# build petsc
WORKDIR /tmp/petsc-build
ARG PETSC_VERSION="3.15.0"
RUN wget http://ftp.mcs.anl.gov/pub/petsc/release-snapshots/petsc-lite-${PETSC_VERSION}.tar.gz
RUN tar zxf petsc-lite-${PETSC_VERSION}.tar.gz
WORKDIR /tmp/petsc-build/petsc-${PETSC_VERSION}
RUN python3 ./configure --with-debugging=0 --prefix=/usr/local \
                --COPTFLAGS="-g -O3" --CXXOPTFLAGS="-g -O3" --FOPTFLAGS="-g -O3" \
                --with-zlib=1                   \
                --download-hdf5=1               \
                --download-mumps=1              \
                --download-parmetis=1           \
                --download-metis=1              \
                --download-superlu=1            \
                # --download-hypre=1              \ # issue with this.. something about difficulty inferring version number
                --download-scalapack=1          \
                --download-superlu_dist=1       \
                --useThreads=0                  \
                --download-superlu=1            \
                --with-shared-libraries         \
                --with-cxx-dialect=C++11        \
                --with-make-np=8
RUN make PETSC_DIR=/tmp/petsc-build/petsc-${PETSC_VERSION} PETSC_ARCH=arch-linux-c-opt all
RUN make PETSC_DIR=/tmp/petsc-build/petsc-${PETSC_VERSION} PETSC_ARCH=arch-linux-c-opt install
# these aren't needed
RUN rm -fr /usr/local/share/petsc 
# I don't think the petsc py package is needed. 
RUN CC=h5pcc HDF5_MPI="ON" HDF5_DIR=/usr/local  pip3 install --no-cache-dir --no-binary=h5py h5py

# minimal install
FROM base_runtime AS minimal
COPY --from=build_base $VIRTUAL_ENV $VIRTUAL_ENV
COPY --from=build_base /usr/local /usr/local
# Record Python packages, but only record system packages! 
# Not venv packages, which will be copied directly in.
RUN PYTHONPATH= /usr/bin/pip3 freeze >/opt/requirements.txt
# Record manually install apt packages.
RUN apt-mark showmanual >/opt/installed.txt

# add tini, user, volume mount and expose port 8888
EXPOSE 8888
ENV NB_USER longgangfan
ENV NB_WORK /home/$NB_USER
ADD https://github.com/krallin/tini/releases/download/v0.18.0/tini /tini
RUN ipcluster nbextension enable \
&&  chmod +x /tini \
&&  useradd -m -s /bin/bash -N $NB_USER -g users \
&&  mkdir -p /$NB_WORK/workspace \
&&  chown -R $NB_USER:users $NB_WORK
VOLUME $NB_WORK/workspace
WORKDIR $NB_WORK

# vim plugin
RUN git clone https://github.com/VundleVim/Vundle.vim.git ./.vim/bundle/Vundle.vim
RUN wget https://raw.githubusercontent.com/longgangfan/vundle-config/main/.vimrc
RUN wget https://raw.githubusercontent.com/longgangfan/vundle-config/main/.vimrc.bundles
RUN vim +PluginInstall +qall

#  user, finalise jupyter env
USER $NB_USER
WORKDIR $NB_WORK
RUN ipython profile create --parallel --profile=mpi \
&&  echo "c.IPClusterEngines.engine_launcher_class = 'MPIEngineSetLauncher'" >> $NB_WORK/.ipython/profile_mpi/ipcluster_config.py
CMD ["jupyter", "notebook", "--no-browser", "--ip='0.0.0.0'"]
