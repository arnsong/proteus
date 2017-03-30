# distutils: language = c++

import os
import sys
import csv
import numpy as np
import mpi4py as MPI
from scipy import spatial
from proteus import AuxiliaryVariables, Archiver, Comm, Profiling
cimport numpy as np
from proteus import SpatialTools as st
from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp cimport bool
from libcpp.memory cimport (shared_ptr,
                            make_shared)
from collections import OrderedDict
from cython.operator cimport dereference as deref
cimport ChronoHeaders as ch


cdef extern from "ChMoorings.h":
    cdef cppclass cppMesh:
        shared_ptr[ch.ChMesh] mesh
        void SetAutomaticGravity(bool val)
    cppMesh * newMesh(ch.ChSystemDEM&, shared_ptr[ch.ChMesh])
    cdef cppclass cppCable:
        ch.ChSystemDEM& system
        ch.ChMesh& mesh
        double L0
        double length
        int nb_elems
        vector[ch.ChVector] mvecs
        void buildNodes()
        void buildMaterials()
        void buildElements()
        void buildMesh()
        void updateDragForces()
        void updateBuoyancyForces()
    cdef cppclass cppMultiSegmentedCable:
        ch.ChSystemDEM& system
        ch.ChMesh& mesh
        vector[shared_ptr[cppCable]] cables
        vector[shared_ptr[ch.ChNodeFEAxyzDD]] nodes
        vector[shared_ptr[ch.ChElementBeamANCF]] elems
        shared_ptr[ch.ChLinkPointFrame] constraint_back
        shared_ptr[ch.ChLinkPointFrame] constraint_front
        void buildNodes()
        void buildCable()
        # void setVelocityAtNodes(double* fluid_velocity)
        void attachFrontNodeToBody(shared_ptr[ch.ChBody])
        void attachBackNodeToBody(shared_ptr[ch.ChBody])
        void updateDragForces()
        void applyForces()
        void updateBuoyancyForces()
        void setFluidVelocityAtNodes(vector[ch.ChVector] fluid_velocity)
        void setFluidDensityAtNodes(vector[double] fluid_density)
        void setContactMaterial(shared_ptr[ch.ChMaterialSurfaceDEM] material)
    cppMultiSegmentedCable * newMoorings(ch.ChSystemDEM& system,
                                         shared_ptr[ch.ChMesh] mesh,
                                         vector[double] length,
                                         vector[int] nb_elems,
                                         vector[double] d,
                                         vector[double] rho,
                                         vector[double] E
        )
    cdef cppclass cppSurfaceBoxNodesCloud:
        ch.ChSystemDEM& system
        ch.ChVector position
        ch.ChVector dimensions
        shared_ptr[ch.ChBodyEasyBox] body;
        void setNodesSize(double size)
    cppSurfaceBoxNodesCloud * newSurfaceBoxNodesCloud(ch.ChSystemDEM& system,
                                                shared_ptr[ch.ChMesh] mesh,
                                                ch.ChVector position,
                                                ch.ChVector dimensions)

cdef extern from "ChRigidBody.h":
    cdef cppclass cppSystem:
        ch.ChSystemDEM system
        void DoStepDynamics(dt)
        void step(double proteus_dt, int n_substeps)
        void recordBodyList()
        void setChTimeStep(double dt)
        void setGravity(double* gravity)
        void setDirectory(string directory)
    cppSystem * newSystem(double* gravity)
    cdef cppclass cppRigidBody:
        shared_ptr[ch.ChBody] body
        double mass
        ch.ChVector pos
        ch.ChVector pos_last
        ch.ChVector vel
        ch.ChVector vel_last
        ch.ChVector acc
        ch.ChVector acc_last
        ch.ChVector angvel
        ch.ChVector angvel_last
        ch.ChVector angacc
        ch.ChVector angacc_last
        # ChVector inertia
        ch.ChMatrix33 rotm
        ch.ChMatrix33 rotm_last
        ch.ChQuaternion rotq
        ch.ChQuaternion rotq_last
        # double* free_x
        # double* free_r
        ch.ChVector F
        ch.ChVector F_last
        ch.ChVector M
        ch.ChVector M_last
        cppRigidBody(cppSystem* system, double* position,
                     double* rotq, double mass, double* inertia,
                     double* free_x, double* free_r)
        void prestep(double* force, double* torque)
        void poststep()
        double hx(double* x, double dt)
        double hy(double* x, double dt)
        double hz(double* x, double dt)
        void addSpring(double stiffness,
                       double damping,
                       double* fairlead,
                       double* anchor,
                       double rest_length)
        void addPrismaticLinksWithSpring(double* pris1,
                                         double* pris2,
                                         double stiffness,
                                         double damping,
                                         double rest_length);
        void setRotation(double* quat)
        void setPosition(double* pos)
        void setConstraints(double* free_x, double* free_r)
        void setInertiaXX(double* inertia)
        void setName(string name)

    cppRigidBody * newRigidBody(cppSystem* system,
                                double* center,
                                double* rot,
                                double mass,
                                double* inertia,
                                double* free_x,
                                double* free_r)

cdef class RigidBody:
    cdef cppRigidBody * thisptr
    cdef public:
      str record_file
      object model
      System system
      object Shape
      int nd, i_start, i_end
      double dt
      object record_dict
      object prescribed_motion_function
      np.ndarray position
      np.ndarray position_last
      np.ndarray F
      np.ndarray M
      np.ndarray F_last
      np.ndarray M_last
      np.ndarray acceleration
      np.ndarray acceleration_last
      np.ndarray velocity
      np.ndarray velocity_last
      np.ndarray ang_acceleration_last
      np.ndarray ang_acceleration
      np.ndarray ang_velocity_last
      np.ndarray ang_velocity
      np.ndarray barycenter0
      np.ndarray rotation_init
      np.ndarray rotm
      np.ndarray rotm_last
      np.ndarray rotq
      np.ndarray rotq_last
      np.ndarray F_prot
      np.ndarray M_prot
      np.ndarray F_prot_last
      np.ndarray M_prot_last
      # np.ndarray free_r
      # np.ndarray free_x
    def __cinit__(self,
                  System system,
                  shape=None,
                  np.ndarray center=None,
                  np.ndarray rot=np.array([1.,0.,0.,0.]),
                  double mass=1.,
                  np.ndarray inertia=np.array([1.,1.,1.]),
                  np.ndarray free_x=np.array([1.,1.,1.]),
                  np.ndarray free_r=np.array([1.,1.,1.])):
        self.system = system
        self.Shape = shape
        if shape is not None:
            self.nd = shape.nd
        self.system.addBody(self)
        self.record_dict = OrderedDict()
        if center is None:
            if shape is not None:
                center = np.array(shape.barycenter)
            else:
                center = np.array([0., 0., 0.])
        self.thisptr = newRigidBody(system.thisptr,
                                    <double*> center.data,
                                    <double*> rot.data,
                                    <double> mass,
                                    <double*> inertia.data,
                                    <double*> free_x.data,
                                    <double*> free_r.data)
        if shape is not None:
            if 'ChRigidBody' not in shape.auxiliaryVariables:
                shape.auxiliaryVariables['ChRigidBody'] = self
                self.setName(shape.name)
        self.F_prot = np.zeros(3)
        self.M_prot = np.zeros(3)
        self.prescribed_motion_function = None

    def attachShape(self, shape):
        assert self.Shape is None, 'Shape '+self.Shape.name+' was already attached'
        self.Shape = shape
        if 'ChRigidBody' not in shape.auxiliaryVariables:
            shape.auxiliaryVariables['ChRigidBody'] = self


    def set_indices(self, i_start, i_end):
        self.i_start = i_start
        self.i_end = i_end

    def attachAuxiliaryVariables(self,avDict):
        pass

    def setInertiaXX(self, np.ndarray inertia):
        self.thisptr.setInertiaXX(<double*> inertia.data)

    def setInitialRot(self, rot):
        cdef np.ndarray zeros = np.zeros(3)
        self.rotation_init = rot
        self.thisptr.prestep(<double*> zeros.data,
                             <double*> zeros.data)
        if self.rotation_init is not None:
            Profiling.logEvent("$$$$$ SETTING ROT")
            self.thisptr.setRotation(<double*> self.rotation_init.data)
        self.thisptr.poststep()

    def hx(self, np.ndarray x, double t):
        return self.thisptr.hx(<double*> x.data, t)

    def hy(self, np.ndarray x, double t):
        return self.thisptr.hy(<double*> x.data, t)

    def hz(self, np.ndarray x, double t):
        return self.thisptr.hz(<double*> x.data, t)

    # def setConstraintsDOF(self, np.ndarray free_x, np.ndarray free_r):
    #     """
    #     Sets constraints on the Shape (for moving bodies)

    #     Parameters
    #     ----------
    #     free_x: array_like
    #         Translational constraints.
    #     free_r: array_like
    #         Rotational constraints.
    #     """
    #     self.thisptr.free_x = <double*> free_x.data
    #     self.thisptr.free_r = <double*> free_r.data
    def addSpring(self, double stiffness, double damping, np.ndarray fairlead,
                  np.ndarray anchor, double rest_length):
        self.thisptr.addSpring(stiffness, damping, <double*> fairlead.data,
                               <double*> anchor.data, rest_length)

    def setPosition(self, np.ndarray position):
        self.thisptr.setPosition(<double*> position.data)

    def setRotation(self, np.ndarray quaternion):
        self.thisptr.setRotation(<double*> quaternion.data)

    def setConstraints(self, np.ndarray free_x, np.ndarray free_r):
        self.thisptr.setConstraints(<double*> free_x.data, <double*> free_r.data)

    def setMass(self, mass):
        """
        Set mass of the shape.
        Parameters
        ----------
        mass: float
            mass of the body
        """
        self.thisptr.mass = <double> mass

    # def setInertiaTensor(self, It):
    #     """
    #     Set the inertia tensor of the shape

    #     Parameters
    #     ----------
    #     It: array_like, float
    #         Inertia tensor of the body (3x3 array in 3D, float in 2D)

    #     Notes
    #     -----
    #     The inertia tensor should not be already scaled with the mass of the
    #     shape.
    #     """
    #     self.thisptr.inertia = <double*> It

    def getPressureForces(self):
        """
        Gives the pressure forces applied on each segments/facets of the rigid
        body
        Returns
        -------
        F_p: array_like
            pressure forces (x, y, z) as provided by Proteus
        """
        i0, i1 = self.i_start, self.i_end
        F_p = self.system.model.levelModelList[-1].coefficients.netForces_p[i0:i1, :]
        F_t = np.sum(F_p, axis=0)
        return F_t

    def getShearForces(self):
        """
        Gives the shear forces applied on each segments/facets of the rigid
        body
        Returns
        -------
        F_v: array_like
            shear forces (x, y, z) as provided by Proteus
        """
        i0, i1 = self.i_start, self.i_end
        F_v = self.system.model.levelModelList[-1].coefficients.netForces_v[i0:i1, :]
        F_t = np.sum(F_v, axis=0)
        return F_t

    def getMoments(self):
        """
        Gives the moments applied on each segments/facets of the rigid body
        Returns
        -------
        M: array_like
            moments (x, y, z) as provided by Proteus
        """
        i0, i1 = self.i_start, self.i_end
        M = self.system.model.levelModelList[-1].coefficients.netMoments[i0:i1, :]
        M_t = np.sum(M, axis=0)
        # !!!!!!!!!!!! UPDATE BARYCENTER !!!!!!!!!!!!
        Fx, Fy, Fz = self.F_prot
        rx, ry, rz = self.barycenter0-self.getPosition()
        Mp = np.array([ry*Fz-rz*Fy, -(rx*Fz-rz*Fx), (rx*Fy-ry*Fx)])
        M_t += Mp
        return M_t

    def getPosition(self):
        x = self.thisptr.pos.x()
        y = self.thisptr.pos.y()
        z = self.thisptr.pos.z()
        return np.array([x, y, z])

    def getRotationQuaternion(self):
        e0 = self.thisptr.rotq.e0()
        e1 = self.thisptr.rotq.e1()
        e2 = self.thisptr.rotq.e2()
        e3 = self.thisptr.rotq.e3()
        return np.array([e0, e1, e2, e3])

    def getRotationMatrix(self):
        x0 = self.thisptr.rotm.Get_A_Xaxis().x()
        x1 = self.thisptr.rotm.Get_A_Xaxis().y()
        x2 = self.thisptr.rotm.Get_A_Xaxis().z()
        y0 = self.thisptr.rotm.Get_A_Yaxis().x()
        y1 = self.thisptr.rotm.Get_A_Yaxis().y()
        y2 = self.thisptr.rotm.Get_A_Yaxis().z()
        z0 = self.thisptr.rotm.Get_A_Zaxis().x()
        z1 = self.thisptr.rotm.Get_A_Zaxis().y()
        z2 = self.thisptr.rotm.Get_A_Zaxis().z()
        matrix = np.array([x0, x1, x2],
                          [y0, y1, y2],
                          [z0, z1, z2])
        return matrix

    def prestep(self):
        if self.system.model is not None:
            self.F_prot_last = np.array(self.F_prot)
            self.M_prot_last = np.array(self.M_prot)
            self.F_prot = self.getPressureForces()+self.getShearForces()
            self.M_prot = self.getMoments()
            self.setExternalForces(self.F_prot, self.M_prot)

    def setExternalForces(self, np.ndarray forces, np.ndarray moments):
        self.thisptr.prestep(<double*> forces.data,
                             <double*> moments.data)

    def poststep(self):
        if self.prescribed_motion_function is not None:
            new_x = self.callPrescribedMotion(self.system.model.stepController.t_model_last)
            self.thisptr.setPosition(<double*> new_x.data)
        self.thisptr.poststep()
        self.getValues()
        comm = Comm.get()
        if comm.isMaster():
            self._recordValues()

    def calculate_init(self):
        # barycenter0 used for moment calculations
        if self.Shape is not None:
            self.barycenter0 = self.Shape.barycenter.copy()
        # get the initial values for F and M
        cdef np.ndarray zeros = np.zeros(3)
        self.setExternalForces(zeros, zeros)
        self.thisptr.poststep()
        self.getValues()
        # self.thisptr.setRotation(<double*> self.rotation_init.data)
        #

    def calculate(self):
        pass

    def setPrescribedMotion(self, function):
        self.prescribed_motion_function = function

    cdef np.ndarray callPrescribedMotion(self, double t):
        return self.prescribed_motion_function(t)

    def getValues(self):
        # position
        self.position = ChVector_to_npArray(self.thisptr.pos)
        self.position_last = ChVector_to_npArray(self.thisptr.pos_last)
        # rotation
        self.rotq = ChQuaternion_to_npArray(self.thisptr.rotq)
        self.rotq_last = ChQuaternion_to_npArray(self.thisptr.rotq_last)
        self.rotm = ChMatrix33_to_npArray(self.thisptr.rotm)
        self.rotm_last = ChMatrix33_to_npArray(self.thisptr.rotm_last)
        # acceleration
        self.acceleration = ChVector_to_npArray(self.thisptr.acc)
        self.acceleration_last = ChVector_to_npArray(self.thisptr.acc_last)
        # velocity
        self.velocity = ChVector_to_npArray(self.thisptr.vel)
        self.velocity_last = ChVector_to_npArray(self.thisptr.vel_last)
        #angular acceleration
        self.ang_acceleration = ChVector_to_npArray(self.thisptr.angacc)
        self.ang_acceleration_last = ChVector_to_npArray(self.thisptr.angacc_last)
        # angular velocity
        self.ang_velocity = ChVector_to_npArray(self.thisptr.angvel)
        self.ang_velocity_last = ChVector_to_npArray(self.thisptr.angvel_last)
        # force
        self.F = ChVector_to_npArray(self.thisptr.F)
        self.F_last = ChVector_to_npArray(self.thisptr.F_last)
        # moment
        self.M = ChVector_to_npArray(self.thisptr.M)
        self.M_last = ChVector_to_npArray(self.thisptr.M_last)
        # self.M_last
        # # self.inertia = ChVector_to_npArray(self.thisptr.)



    def setRecordValues(self, filename=None, all_values=False, pos=False,
                        rot=False, ang_disp=False, F=False, M=False,
                        inertia=False, vel=False, acc=False, ang_vel=False, ang_acc=False):
        """
        Sets the rigid body attributes that are to be recorded in a csv file
        during the simulation.
        Parameters
        ----------
        filename: Optional[string]
            Name of file, if not set, the file will be named as follows:
            'record_[shape.name].csv'
        all_values: bool
            Set to True to record all values listed below.
        time: bool
            Time of recorded row (default: True).
        pos: bool
            Position of body (default: False. Set to True to record).
        rot: bool
            Rotation of body (default: False. Set to True to record).
        ang_disp: array
            Angular displecement calculated during rigid body calculation step.
            Applied on the body in order to make it rotating.
        F: bool
            Forces applied on body (default: False. Set to True to record).
        M: bool
            Moments applied on body (default: False. Set to True to record).
        inertia: bool
            Inertia of body (default: False. Set to True to record).
        vel: bool
            Velocity of body (default: False. Set to True to record).
        acc: bool
            Acceleration of body (default: False. Set to True to record).
        ang_vel: array
            Angular velocity of body (default: False. Set to True to record).
        ang_acc: bool
            Angular acceleration of body (default: False. Set to True to record).
        Notes
        -----
        To add another value manually, add to dictionary self.record_dict:
        key: header of the column in .csv
        value: list of length 2: [variable name, index within variable]
                                                 (if no index, use None)
        e.g. self.record_dict['m']['mass', None]
        """
        if all_values is True:
            pos = rot = F = M = acc = vel = ang_acc = ang_vel = True
        if pos is True:
            self.record_dict['x'] = ['position_last', 0]
            self.record_dict['y'] = ['position_last', 1]
            self.record_dict['z'] = ['position_last', 2]
        # if rot is True:
        #     self.record_dict['rx'] = ['last_rotation_euler', 0]
        #     self.record_dict['ry'] = ['last_rotation_euler', 1]
        #     self.record_dict['rz'] = ['last_rotation_euler', 2]
        if rot is True:
            self.record_dict['rotq_e0'] = ['rotq_last', 0]
            self.record_dict['rotq_e1'] = ['rotq_last', 1]
            self.record_dict['rotq_e2'] = ['rotq_last', 2]
            self.record_dict['rotq_e3'] = ['rotq_last', 3]
            # self.record_dict['rotm_a11'] = ['rotm_last', (0,0)]
            # self.record_dict['rotm_a12'] = ['rotm_last', (0,1)]
            # self.record_dict['rotm_a13'] = ['rotm_last', (0,2)]
            # self.record_dict['rotm_a21'] = ['rotm_last', (1,0)]
            # self.record_dict['rotm_a22'] = ['rotm_last', (1,1)]
            # self.record_dict['rotm_a23'] = ['rotm_last', (1,2)]
            # self.record_dict['rotm_a31'] = ['rotm_last', (2,0)]
            # self.record_dict['rotm_a32'] = ['rotm_last', (2,1)]
            # self.record_dict['rotm_a33'] = ['rotm_last', (2,2)]
        if F is True:
            self.record_dict['Fx'] = ['F', 0]
            self.record_dict['Fy'] = ['F', 1]
            self.record_dict['Fz'] = ['F', 2]
            self.record_dict['Fx_prot'] = ['F_prot', 0]
            self.record_dict['Fy_prot'] = ['F_prot', 1]
            self.record_dict['Fz_prot'] = ['F_prot', 2]
            Fx = Fy = Fz = True
        if M is True:
            self.record_dict['Mx'] = ['M', 0]
            self.record_dict['My'] = ['M', 1]
            self.record_dict['Mz'] = ['M', 2]
            self.record_dict['Mx_prot'] = ['M_prot', 0]
            self.record_dict['My_prot'] = ['M_prot', 1]
            self.record_dict['Mz_prot'] = ['M_prot', 2]
        if acc is True:
            self.record_dict['ax'] = ['acceleration_last', 0]
            self.record_dict['ay'] = ['acceleration_last', 1]
            self.record_dict['az'] = ['acceleration_last', 2]
        if vel is True:
            self.record_dict['ux'] = ['velocity_last', 0]
            self.record_dict['uy'] = ['velocity_last', 1]
            self.record_dict['uz'] = ['velocity_last', 2]
        if ang_acc is True:
            self.record_dict['ang_ax'] = ['ang_acceleration_last', 0]
            self.record_dict['ang_ay'] = ['ang_acceleration_last', 1]
            self.record_dict['ang_az'] = ['ang_acceleration_last', 2]
        if ang_vel is True:
            self.record_dict['ang_ux'] = ['ang_velocity_last', 0]
            self.record_dict['ang_uy'] = ['ang_velocity_last', 1]
            self.record_dict['ang_uz'] = ['ang_velocity_last', 2]
        if inertia is True:
            self.record_dict['intertia'] = ['inertia', None]

    def _recordValues(self):
        """
        Records values of rigid body attributes at each time step in a csv file.
        """
        if self.Shape is not None:
            self.record_file = os.path.join(Profiling.logDir, 'record_' + self.Shape.name + '.csv')
        else:
            self.record_file = os.path.join(Profiling.logDir, 'record_' + 'body' + '.csv')
        if self.system.model is not None:
            t_last = self.system.model.stepController.t_model_last
            dt_last = self.system.model.levelModelList[-1].dt_last
            t = t_last-dt_last
        else:
            t = self.system.thisptr.system.GetChTime()
        t_prot = Profiling.time()-Profiling.startTime
        values_towrite = [t, t_prot]
        if t == 0:
            headers = ['t', 't_prot']
            for key in self.record_dict:
                headers += [key]
            with open(self.record_file, 'w') as csvfile:
                writer = csv.writer(csvfile, delimiter=',')
                writer.writerow(headers)
        for key, val in self.record_dict.iteritems():
            if val[1] is not None:
                values_towrite += [getattr(self, val[0])[val[1]]]
            else:
                values_towrite += [getattr(self, val[0])]
        with open(self.record_file, 'a') as csvfile:
            writer = csv.writer(csvfile, delimiter=',')
            writer.writerow(values_towrite)

    def addPrismaticLinksWithSpring(self, np.ndarray pris1,
                                    np.ndarray pris2, double stiffness, double damping,
                                    double rest_length):
        """
        fairlead: barycenter coords
        pris: absolute coords
        pris1-------fairlead(barycenter)
        |
        |
        |
        |
        pris2
        """
        self.thisptr.addPrismaticLinksWithSpring(<double*> pris1.data, 
                                                 <double*> pris2.data,
                                                 stiffness,
                                                 damping,
                                                 rest_length)

    def setName(self, string name):
        self.thisptr.setName(name)


cdef class System:
    cdef cppSystem * thisptr
    cdef public object model
    cdef object bodies
    cdef object moorings
    cdef public double dt_init
    cdef double proteus_dt
    cdef double chrono_dt
    cdef string directory
    cdef object u
    cdef int nd
    cdef object femSpace_velocity
    cdef object femSpace_pressure
    cdef object nodes_kdtree
    def __cinit__(self, np.ndarray gravity, int nd=3):
        self.thisptr = newSystem(<double*> gravity.data)
        self.bodies = []
        self.moorings = []
        self.dt_init = 0.001
        self.model = None
        self.nd = nd

    def attachModel(self, model, ar):
        self.model = model
        return self

    def attachAuxiliaryVariables(self,avDict):
        pass

    def calculate(self, proteus_dt=None):
        if self.model is not None:
            try:
                self.proteus_dt = self.model.levelModelList[-1].dt_last
            except:
                self.proteus_dt = self.dt_init
        elif proteus_dt is not None:
            self.proteus_dt = proteus_dt
        else:
            sys.exit('no time step set')
        Profiling.logEvent('Solving Chrono system for dt='+str(self.proteus_dt))
        print('Solving Chrono system for dt='+str(self.proteus_dt))
        if self.model is not None:
            self.nodes_kdtree = spatial.cKDTree(self.model.levelModelList[-1].mesh.nodeArray)
        for mooring in self.moorings:
            mooring.prestep()
        for body in self.bodies:
            body.prestep()
        self.step(self.proteus_dt)
        for body in self.bodies:
            body.poststep()
        for mooring in self.moorings:
            mooring.poststep()
        Profiling.logEvent('Solved Chrono system to t='+str(self.thisptr.system.GetChTime()))
        print('Solved Chrono system to t='+str(self.thisptr.system.GetChTime()))
        #self.recordBodyList()

    def calculate_init(self):
        self.directory = str(Profiling.logDir)+'/'
        self.thisptr.setDirectory(self.directory)
        if self.model is not None:
            self.u = self.model.levelModelList[-1].u
            # finite element space (! linear for p, quadratic for velocity)
            self.femSpace_velocity = self.u[1].femSpace
            self.femSpace_pressure = self.u[0].femSpace
            self.nodes_kdtree = spatial.cKDTree(self.model.levelModelList[-1].mesh.nodeArray)
        for body in self.bodies:
            body.calculate_init()
        for mooring in self.moorings:
            mooring.calculate_init()
        self.thisptr.system.SetupInitial()

    def setTimeStep(self, double dt):
        """Sets time step for Chrono solver.
        Calculations in Chrono will use this time step within the
        Proteus time step (if bigger)
        Parameters
        ----------
        dt: float
            time step
        """
        self.chrono_dt = dt
        self.thisptr.setChTimeStep(dt)

    def setGravity(self, np.ndarray gravity):
        self.thisptr.setGravity(<double*> gravity.data)

    def step(self, double dt):
        steps = max(int(dt/self.chrono_dt), 1)
        self.thisptr.step(<double> dt, n_substeps=steps)

    def addBody(self, body):
        self.bodies += [body]

    def addMoorings(self, moorings):
        self.moorings += [moorings]

    def recordBodyList(self):
        comm = Comm.get()
        if comm.isMaster():
            self.thisptr.recordBodyList()

    def findFluidVelocityAtCoords(self, coords):
        """Finds solution from NS for velocity of fluid at given coordinates

        Parameters
        ----------
        coords: array_like
            coordinates at which velocity solution is sought

        Returns
        -------
        u: float
            velocity in the x direction
        v: float
            velocity in the y direction
        w: float
            velocity in the z direction (0 if 2D)
        """
        comm = Comm.get().comm.tompi4py()
        # get nearest node on each processor
        nearest_node, nearest_node_distance = getLocalNearestNode(coords, self.nodes_kdtree)
        # look for element containing coords on each processor (if it exists)
        local_element = getLocalElement(self.femSpace_velocity, coords, nearest_node)
        # check which processor has element (if any)
        haveElement = int(local_element is not None)
        if haveElement:
            owning_proc = comm.rank
        if local_element:
            # NEXT LINE TO CHANGE
            nd = self.nd
            # get local coords
            xi = self.femSpace_velocity.elementMaps.getInverseValue(local_element, coords)
            # get solution
            u = self.u[1].getValue(local_element, xi)
            v = self.u[2].getValue(local_element, xi)
            if nd > 2:
                w = self.u[3].getValue(local_element, xi)
            # broadcast to all processors
            u = comm.bcast(u, owning_proc)
            v = comm.bcast(v, owning_proc)
            if nd > 2:
                w = comm.bcast(w, owning_proc)
            if nd <= 2:
                w = 0
        else:
            sys.exit('{coords} outside of domain'.format(coords=str(coords)))
        return u, v, w

# ctypedef np.ndarray vecarray(ChVector)

# ctypedef np.ndarray (*ChVector_to_npArray) (ChVector)
cdef np.ndarray ChVector_to_npArray(ch.ChVector &myvec):
    return np.array([myvec.x(), myvec.y(), myvec.z()])

cdef np.ndarray ChQuaternion_to_npArray(ch.ChQuaternion &quat):
    return np.array([quat.e0(), quat.e1(), quat.e2(), quat.e3()])

cdef np.ndarray ChMatrix33_to_npArray(ch.ChMatrix33 &mat):
    return np.array([[mat.Get_A_Xaxis().x(), mat.Get_A_Xaxis().y(), mat.Get_A_Xaxis().z()],
                     [mat.Get_A_Yaxis().x(), mat.Get_A_Yaxis().y(), mat.Get_A_Yaxis().z()],
                     [mat.Get_A_Zaxis().x(), mat.Get_A_Zaxis().y(), mat.Get_A_Zaxis().z()]])

#def testx():
#    cdef ChSystem system = ChSystem()
#    cdef ChBody bod = ChBody()
#    cdef ChVector oo = ChVector[double](2.,3.,4.)
#    bod.SetPos_dt(oo)
#    cdef ChVector& gg = bod.GetPos_dt()
#    print(gg.x, gg.y, gg.z)


cdef class Mesh:
    cdef cppMesh * thisptr
    def __cinit__(self, System system):
        cdef shared_ptr[ch.ChMesh] mesh = make_shared[ch.ChMesh]()
        self.thisptr = newMesh(system.thisptr.system, mesh)
    def setAutomaticGravity(self, bool val):
        self.thisptr.SetAutomaticGravity(val)

cdef class SurfaceBoxNodesCloud:
    cdef cppSurfaceBoxNodesCloud * thisptr
    def __cinit__(self, System system, Mesh mesh, np.ndarray position, np.ndarray dimensions):
        cdef ch.ChVector[double] pos = ch.ChVector[double](position[0], position[1], position[2])
        cdef ch.ChVector[double] dim = ch.ChVector[double](dimensions[0], dimensions[1], dimensions[2])
        self.thisptr = newSurfaceBoxNodesCloud(system.thisptr.system,
                                               mesh.thisptr.mesh,
                                               pos,
                                               dim)
        # self.System.addBody(self)
    def setNodesSize(self, double size):
        self.thisptr.setNodesSize(size)


cdef class Moorings:
    cdef cppMultiSegmentedCable * thisptr
    cdef public:
      str record_file
      object model
      System System
      object Mesh
      int nd
      object nodes_function
      RigidBody body_front
      RigidBody body_back
      bool front_body
      bool back_body
      bool nodes_built
      np.ndarray fluid_density_array
      np.ndarray fluid_velocity_array
    def __cinit__(self,
                  System system,
                  Mesh mesh,
                  np.ndarray length,
                  np.ndarray nb_elems,
                  np.ndarray d,
                  np.ndarray rho,
                  np.ndarray E):
        self.System = system
        self.System.addMoorings(self)
        self.nd = self.System.nd
        self.Mesh = mesh
        cdef vector[double] vec_length
        cdef vector[int] vec_nb_elems
        cdef vector[double] vec_d
        cdef vector[double] vec_rho
        cdef vector[double] vec_E
        for i in range(len(length)):
            vec_length.push_back(length[i])
            vec_nb_elems.push_back(nb_elems[i])
            vec_d.push_back(d[i])
            vec_rho.push_back(rho[i])
            vec_E.push_back(E[i])
        self.thisptr = newMoorings(system.thisptr.system,
                                   mesh.thisptr.mesh,
                                   vec_length,
                                   vec_nb_elems,
                                   vec_d,
                                   vec_rho,
                                   vec_E
                                   )
        self.nodes_function = lambda s: (s, s, s)
        self.nodes_built = False

    def _recordValues(self):
        self.record_file = os.path.join(Profiling.logDir, 'record_moorings.csv')
        if self.system.model is not None:
            t_last = self.system.model.stepController.t_model_last
            dt_last = self.system.model.levelModelList[-1].dt_last
            t = t_last-dt_last
        else:
            t = self.system.thisptr.system.GetChTime()
        if t == 0:
            headers = ['t', 't_prot']
            for i in len(self.thisptr.nodes.size()):
                headers += ['x'+str(i), 'y'+str(i), 'z'+str(i)]
            with open(self.record_file, 'w') as csvfile:
                writer = csv.writer(csvfile, delimiter=',')
                writer.writerow(headers)
        row = []
        cdef ch.ChVector vec
        for i in range(self.thisptr.nodes.size()):
            vec = deref(self.thisptr.nodes[i]).GetPos()
            x = vec.x()
            y = vec.y()
            z = vec.z()
            row += [x, y, z]
        with open(self.record_file, 'a') as csvfile:
            writer = csv.writer(csvfile, delimiter=',')
            writer.writerow(row)

    def getTensionBack(self):
        cdef ch.ChVector T
        if self.thisptr.constraint_back:
            T = deref(self.thisptr.constraint_back).GetReactionOnNode()
            return ChVector_to_npArray(T)
        else:
            return np.zeros(3)

    def getTensionFront(self):
        cdef ch.ChVector T
        if self.thisptr.constraint_front:
            T = deref(self.thisptr.constraint_front).GetReactionOnNode()
            return ChVector_to_npArray(T)
        else:
            return np.zeros(3)

    def calculate_init(self):
        # build position vector of nodes (for each segment)
        # self.setNodesPosition()
        # build cable (nodes, elements, etc)
        self.thisptr.buildCable()
        nb_nodes = self.thisptr.nodes.size()
        if self.fluid_velocity_array is None:
            self.fluid_velocity_array = np.zeros((nb_nodes, 3))
        if self.fluid_density_array is None:
            self.fluid_density_array = np.zeros(nb_nodes)+998.2


    def prestep(self):
        if self.System.model is not None:
            self.setExternalForces()

    def poststep(self):
        pass

    def setNodesPositionFunction(self, function):
        """Function to build nodes

        Must be a function taking one argument (e.g. distance along cable) and
        returning 3 arguments (x, y, z) coordinates
        """
        self.nodes_function = function

    def fixFrontNode(self, bool fixed):
        """Fix front node of cable

        Parameters
        ----------
        fixed: bool
            Fixes node if True
        """
        assert self.nodes_built is True, 'call buildNodes() before calling this function'
        deref(self.thisptr.nodes.front()).SetFixed(fixed)

    def fixBackNode(self, bool fixed):
        """Fix back node of cable

        Parameters
        ----------
        fixed: bool
            Fixes node if True
        """
        assert self.nodes_built is True, 'call buildNodes() before calling this function'
        deref(self.thisptr.nodes.back()).SetFixed(fixed)

    def attachBackNodeToBody(self, RigidBody body):
        assert self.nodes_built is True, 'call buildNodes() before calling this function'
        self.thisptr.attachBackNodeToBody(body.thisptr.body)

    def attachFrontNodeToBody(self, RigidBody body):
        assert self.nodes_built is True, 'call buildNodes() before calling this function'
        self.thisptr.attachFrontNodeToBody(body.thisptr.body)

    def getLengthElems(self):
        lengths = np.zeros(self.thisptr.elems.size())
        for i in range(self.thisptr.elems.size()):
            lengths[i] = deref(self.thisptr.elems[i]).GetLengthX()
        return lengths

    def setNodesPosition(self):
        cdef ch.ChVector[double] vec
        for i in range(self.thisptr.cables.size()):
            deref(self.thisptr.cables[i]).mvecs.clear()
            L0 = deref(self.thisptr.cables[i]).L0
            L = deref(self.thisptr.cables[i]).length
            nb_elems = deref(self.thisptr.cables[i]).nb_elems
            nb_nodes = nb_elems*2+1
            ds = L/(nb_nodes-1)
            for j in range(nb_nodes):
                x, y, z = self.nodes_function(L0+ds*j)
                vec = ch.ChVector[double](x, y, z)
                deref(self.thisptr.cables[i]).mvecs.push_back(vec)
        self.buildNodes()

    def buildNodes(self):
        self.thisptr.buildNodes()
        self.nodes_built = True

    def getNodesPosition(self):
        pos = np.zeros(( self.thisptr.nodes.size(),3 ))
        for i in range(self.thisptr.nodes.size()):
            vec = deref(self.thisptr.nodes[i]).GetPos()
            pos[i] = [vec.x(), vec.y(), vec.z()]
        return pos

    def setContactMaterial(self, ChMaterialSurfaceDEM mat):
        self.thisptr.setContactMaterial(mat.sharedptr)

    def setExternalForces(self, fluid_velocity_array=None, fluid_density_array=None):
        """
        Sets external forces acting on cables
        Pass fluid velocity_array as argument only for debugging (must be an array as long as the number of nodes)
        """
        # get velocity at nodes
        # cdef np.ndarray fluid_velocity = np.zeros((len(self.thisptr.nodes.size()), 3))
        if fluid_velocity_array is not None:
            self.fluid_velocity_array = fluid_velocity_array
        if fluid_density_array is not None:
            self.fluid_density_array = fluid_density_array
        cdef vector[ch.ChVector[double]] fluid_velocity
        cdef ch.ChVector[double] vel
        cdef vector[double] fluid_density
        cdef double dens
        if self.System.model is not None or (fluid_velocity_array is not None and fluid_density_array is not None):
            for i in range(self.thisptr.nodes.size()):
                if self.System.model is not None and fluid_velocity_array is None:
                    vec = deref(self.thisptr.nodes[i]).GetPos()
                    x = vec.x()
                    y = vec.y()
                    z = vec.z()
                    coords = np.array([x, y, z])
                    arr = np.zeros(3)
                    arr[:self.nd] = self.System.findFluidVelocityAtCoords(coords[:self.nd])
                    self.fluid_velocity_array[i] = arr
                    vel = ch.ChVector[double](arr[0], arr[1], arr[2])
                    fluid_velocity.push_back(vel)
                elif fluid_velocity_array is not None:
                    vel = ch.ChVector[double](self.fluid_velocity_array[i][0], fluid_velocity_array[i][1], fluid_velocity_array[i][2])
                    fluid_velocity.push_back(vel)
                    dens = self.fluid_density_array[i]
                    fluid_density.push_back(dens)
            self.thisptr.setFluidVelocityAtNodes(fluid_velocity)
            self.thisptr.setFluidDensityAtNodes(fluid_density)
            # update drag forces
            self.thisptr.updateDragForces()
            self.thisptr.applyForces()
        # update buoyancy forces
        # self.thisptr.updateBuoyancyForces()
        # update added mass forces
        # self.thisptr.updateAddedMassForces()


def getLocalNearestNode(coords, kdtree):
    """Finds nearest node to coordinates (local)
    Parameters
    ----------
    coords: array_like
        coordinates from which to find nearest node
    kdtree: scipy.spatial.cKDTree
        instance of scipy kdtree

    Returns
    -------
    node: int
        nearest node index
    distance: float
        distance to nearest node
    """
    # determine local nearest node distance
    distance, node = kdtree.query(coords)
    return node, distance

def getLocalElement(femSpace, coords, node):
    """Given coordinates and its nearest node, determine if it is on a
    local element.

    Parameters
    ----------
    femSpace: object
        finite element space
    coords: array_like
        coordinates from which to element
    node: int
        nearest node index

    Returns
    -------
    eN: int or None
        local index of element (None if not found)
    """
    patchBoundaryNodes=set()
    checkedElements=[]
    # nodeElementOffsets give the indices to get the elements sharing the node
    for eOffset in range(femSpace.mesh.nodeElementOffsets[node], femSpace.mesh.nodeElementOffsets[node + 1]):
        eN = femSpace.mesh.nodeElementsArray[eOffset]
        checkedElements.append(eN)
        # union of set
        patchBoundaryNodes|=set(femSpace.mesh.elementNodesArray[eN])
        # evaluate the inverse map for element eN (global to local)
        xi = femSpace.elementMaps.getInverseValue(eN, coords)
        # query whether xi lies within the reference element
        if femSpace.elementMaps.referenceElement.onElement(xi):
            return eN
    # extra loop if case coords is in neighbour element
    for node in patchBoundaryNodes:
        for eOffset in range(femSpace.mesh.nodeElementOffsets[node], femSpace.mesh.nodeElementOffsets[node + 1]):
            eN = femSpace.mesh.nodeElementsArray[eOffset]
            if eN not in checkedElements:
                checkedElements.append(eN)
                # evaluate the inverse map for element eN
                xi = femSpace.elementMaps.getInverseValue(eN, coords)
                # query whether xi lies within the reference element
                if femSpace.elementMaps.referenceElement.onElement(xi):
                    return eN
    # no elements found
    return None

cdef class ChMaterialSurfaceDEM:
    cdef shared_ptr[ch.ChMaterialSurfaceDEM] sharedptr
    def __cinit__(self):
        self.sharedptr = make_shared[ch.ChMaterialSurfaceDEM]()
    def SetYoungModulus(self, float val):
        deref(self.sharedptr).SetYoungModulus(val)
    def SetPoissonRatio(self, float val):
        deref(self.sharedptr).SetPoissonRatio(val)
    def SetSfriction(self, float val):
        deref(self.sharedptr).SetSfriction(val)
    def SetKfriction(self, float val):
        deref(self.sharedptr).SetKfriction(val)
    def SetFriction(self, float val):
        deref(self.sharedptr).SetFriction(val)
    def SetRestitution(self, float val):
        deref(self.sharedptr).SetRestitution(val)
    def SetAdhesion(self, float val):
        deref(self.sharedptr).SetAdhesion(val)
    def SetAdhesionMultDMT(self, float val):
        deref(self.sharedptr).SetAdhesionMultDMT(val)
    def SetKn(self, float val):
        deref(self.sharedptr).SetKn(val)
    def SetKt(self, float val):
        deref(self.sharedptr).SetKt(val)
    def SetGn(self, float val):
        deref(self.sharedptr).SetGn(val)
    def SetGt(self, float val):
        deref(self.sharedptr).SetGt(val)

cdef class ChContactSurfaceNodeCloud:
    cdef shared_ptr[ch.ChContactSurfaceNodeCloud] sharedptr
    def __cinit__(self):
        self.sharedptr = make_shared[ch.ChContactSurfaceNodeCloud]()
    def AddAllNodes(self, double point_radius=0.001):
        deref(self.sharedptr).AddAllNodes(point_radius)

cdef class ChVector:
    cdef shared_ptr[ch.ChVector] sharedptr
    def __cinit__(self, double x, double y, double z):
        self.sharedptr = make_shared[ch.ChVector](x, y, z)
    def x(self):
        return deref(self.sharedptr).x()
    def y(self):
        return deref(self.sharedptr).y()
    def z(self):
        return deref(self.sharedptr).z()

cdef class ChQuaternion:
    cdef shared_ptr[ch.ChQuaternion] sharedptr
    def __cinit__(self, double e0, double e1, double e2, double e3):
        self.sharedptr = make_shared[ch.ChQuaternion](e0, e1, e2, e3)
    def e0(self):
        return deref(self.sharedptr).e0()
    def e1(self):
        return deref(self.sharedptr).e1()
    def e2(self):
        return deref(self.sharedptr).e2()
    def e3(self):
        return deref(self.sharedptr).e3()

cdef class ChBody:
    cdef shared_ptr[ch.ChBody] sharedptr
    def __cinit__(self):
        if type(self) is ChBody:
            self.sharedptr = make_shared[ch.ChBody]()
    def SetBodyFixed(self, bool state):
        deref(self.sharedptr).SetBodyFixed(state)
    def SetRot(self, ChQuaternion rot):
        deref(self.sharedptr).SetRot(deref(rot.sharedptr))
    def SetPos(self, ChVector mpos):
        deref(self.sharedptr).SetPos(<ch.ChVector> deref(mpos.sharedptr))
    def SetMaterialSurface(self, ChMaterialSurfaceDEM mat):
        deref(self.sharedptr).SetMaterialSurface(<shared_ptr[ch.ChMaterialSurfaceBase]> mat.sharedptr)

cdef class ChBodyEasyBox(ChBody):
    cdef shared_ptr[ch.ChBodyEasyBox] sharedptr2
    def __cinit__(self, System system, double Xsize, double Ysize, double Zsize, double mdensity, bool collide=True, bool visual_asset=False):
        self.sharedptr2 = make_shared[ch.ChBodyEasyBox](Xsize, Ysize, Zsize, mdensity, collide, visual_asset)
        self.sharedptr = <shared_ptr[ch.ChBody]> self.sharedptr2
        system.thisptr.system.Add(<shared_ptr[ch.ChPhysicsItem]> self.sharedptr2)
