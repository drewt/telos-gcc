------------------------------------------------------------------------------
--                                                                          --
--                 GNU ADA RUN-TIME LIBRARY (GNARL) COMPONENTS              --
--                                                                          --
--                             S Y S T E M . I N I T                        --
--                                                                          --
--                                   B o d y                                --
--                                                                          --
--           Copyright (C) 2003 Free Software Foundation, Inc.              --
--                                                                          --
-- GNARL is free software; you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 2,  or (at your option) any later ver- --
-- sion. GNARL is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNARL; see file COPYING.  If not, write --
-- to  the Free Software Foundation,  59 Temple Place - Suite 330,  Boston, --
-- MA 02111-1307, USA.                                                      --
--                                                                          --
-- As a special exception,  if other files  instantiate  generics from this --
-- unit, or you link  this unit with other files  to produce an executable, --
-- this  unit  does not  by itself cause  the resulting  executable  to  be --
-- covered  by the  GNU  General  Public  License.  This exception does not --
-- however invalidate  any other reasons why  the executable file  might be --
-- covered by the  GNU Public License.                                      --
--                                                                          --
-- GNARL was developed by the GNARL team at Florida State University.       --
-- Extensive contributions were provided by Ada Core Technologies, Inc.     --
--                                                                          --
------------------------------------------------------------------------------

--  This is the VxWorks version of this package

with System.OS_Interface;
--  used for various Constants, Signal and types

with Interfaces.C;
--  used for int and other types

with Ada.Exceptions;
--  used for Raise_Exception

package body System.Init is

   --  This unit contains initialization circuits that are system dependent.

   use Ada.Exceptions;
   use System.OS_Interface;
   use type Interfaces.C.int;

   --  Copies of global values computed by the binder
   Gl_Main_Priority : Integer := -1;
   pragma Export (C, Gl_Main_Priority, "__gl_main_priority");

   Gl_Time_Slice_Val : Integer := -1;
   pragma Export (C, Gl_Time_Slice_Val, "__gl_time_slice_val");

   Gl_Wc_Encoding : Character := 'n';
   pragma Export (C, Gl_Wc_Encoding, "__gl_wc_encoding");

   Gl_Locking_Policy : Character := ' ';
   pragma Export (C, Gl_Locking_Policy, "__gl_locking_policy");

   Gl_Queuing_Policy : Character := ' ';
   pragma Export (C, Gl_Queuing_Policy, "__gl_queuing_policy");

   Gl_Task_Dispatching_Policy : Character := ' ';
   pragma Export (C, Gl_Task_Dispatching_Policy,
                     "__gl_task_dispatching_policy");

   Gl_Restrictions : Address := Null_Address;
   pragma Export (C, Gl_Restrictions, "__gl_restrictions");

   Gl_Interrupt_States : Address := Null_Address;
   pragma Export (C, Gl_Interrupt_States, "__gl_interrupt_states");

   Gl_Num_Interrupt_States : Integer := 0;
   pragma Export (C, Gl_Num_Interrupt_States, "__gl_num_interrupt_states");

   Gl_Unreserve_All_Interrupts : Integer := 0;
   pragma Export (C, Gl_Unreserve_All_Interrupts,
                  "__gl_unreserve_all_interrupts");

   Gl_Exception_Tracebacks : Integer := 0;
   pragma Export (C, Gl_Exception_Tracebacks, "__gl_exception_tracebacks");

   Gl_Zero_Cost_Exceptions : Integer := 0;
   pragma Export (C, Gl_Zero_Cost_Exceptions, "__gl_zero_cost_exceptions");

   Already_Called : Boolean := False;

   Handler_Installed : Integer := 0;
   --  Indication of whether synchronous signal handlers have already been
   --  installed by a previous call to Install_Handler.
   pragma Export (C, Handler_Installed, "__gnat_handler_installed");

   ------------------------
   --  Local procedures  --
   ------------------------

   procedure GNAT_Error_Handler (Sig : Signal);
   --  Common procedure that is executed when a SIGFPE, SIGILL,
   --  SIGSEGV, or SIGBUS is captured.

   procedure Install_Handler;
   pragma Export (C, Install_Handler, "__gnat_install_handler");
   --  Install handler for the synchronous signals. The C profile
   --  here is what is expected by the binder-generated main.

   ------------------------
   -- GNAT_Error_Handler --
   ------------------------

   procedure GNAT_Error_Handler (Sig : Signal) is
      Mask   : aliased sigset_t;
      Result : int;

   begin
      --  VxWorks will always mask out the signal during the signal
      --  handler and will reenable it on a longjmp.  GNAT does not
      --  generate a longjmp to return from a signal handler so the
      --  signal will still be masked unless we unmask it.

      Result := pthread_sigmask (SIG_SETMASK, null, Mask'Unchecked_Access);
      Result := sigdelset (Mask'Access, Sig);
      Result := pthread_sigmask (SIG_SETMASK, Mask'Unchecked_Access, null);

      case Sig is
         when SIGFPE =>
            Raise_Exception (Constraint_Error'Identity, "SIGFPE");
         when SIGILL =>
            Raise_Exception (Constraint_Error'Identity, "SIGILL");
         when SIGSEGV =>
            Raise_Exception
              (Program_Error'Identity,
               "erroneous memory access");
         when SIGBUS =>
            Raise_Exception
              (Storage_Error'Identity,
               "stack overflow or SIGBUS");
         when others =>
            Raise_Exception (Program_Error'Identity, "unhandled signal");
      end case;
   end GNAT_Error_Handler;

   -----------------
   -- Set_Globals --
   -----------------

   --  This routine is called from the binder generated main program.  It
   --  copies the values for global quantities computed by the binder
   --  into the following global locations. The reason that we go through
   --  this copy, rather than just define the global locations in the
   --  binder generated file, is that they are referenced from the
   --  runtime, which may be in a shared library, and the binder file is
   --  not in the shared library. Global references across library
   --  boundaries like this are not handled correctly in all systems.

   procedure Set_Globals
     (Main_Priority            : Integer;
      Time_Slice_Value         : Integer;
      WC_Encoding              : Character;
      Locking_Policy           : Character;
      Queuing_Policy           : Character;
      Task_Dispatching_Policy  : Character;
      Restrictions             : System.Address;
      Interrupt_States         : System.Address;
      Num_Interrupt_States     : Integer;
      Unreserve_All_Interrupts : Integer;
      Exception_Tracebacks     : Integer;
      Zero_Cost_Exceptions     : Integer) is
   begin
      --  If this procedure has been already called once, check that the
      --  arguments in this call are consistent with the ones in the
      --  previous calls. Otherwise, raise a Program_Error exception.
      --
      --  We do not check for consistency of the wide character encoding
      --  method. This default affects only Wide_Text_IO where no
      --  explicit coding method is given, and there is no particular
      --  reason to let this default be affected by the source
      --  representation of a library in any case.
      --
      --  We do not check either for the consistency of exception tracebacks,
      --  because exception tracebacks are not normally set in Stand-Alone
      --  libraries. If a library or the main program set the exception
      --  tracebacks, then they are never reset afterwards (see below).
      --
      --  The value of main_priority is meaningful only when we are
      --  invoked from the main program elaboration routine of an Ada
      --  application. Checking the consistency of this parameter should
      --  therefore not be done. Since it is assured that the main
      --  program elaboration will always invoke this procedure before
      --  any library elaboration routine, only the value of
      --  main_priority during the first call should be taken into
      --  account and all the subsequent ones should be ignored. Note
      --  that the case where the main program is not written in Ada is
      --  also properly handled, since the default value will then be
      --  used for this parameter.
      --
      --  For identical reasons, the consistency of time_slice_val should
      --  not be checked.

      if Already_Called then
         if (Gl_Locking_Policy           /= Locking_Policy) or
            (Gl_Queuing_Policy           /= Queuing_Policy) or
            (Gl_Task_Dispatching_Policy  /= Task_Dispatching_Policy) or
            (Gl_Unreserve_All_Interrupts /= Unreserve_All_Interrupts) or
            (Gl_Exception_Tracebacks     /= Exception_Tracebacks) or
            (Gl_Zero_Cost_Exceptions     /= Zero_Cost_Exceptions)
         then
            raise Program_Error;
         end if;

         --  If either a library or the main program set the exception
         --  traceback flag, it is never reset later.

         if Gl_Exception_Tracebacks /= 0 then
            Gl_Exception_Tracebacks := Exception_Tracebacks;
         end if;

      else
         Already_Called := True;

         Gl_Main_Priority            := Main_Priority;
         Gl_Time_Slice_Val           := Time_Slice_Value;
         Gl_Wc_Encoding              := WC_Encoding;
         Gl_Locking_Policy           := Locking_Policy;
         Gl_Queuing_Policy           := Queuing_Policy;
         Gl_Task_Dispatching_Policy  := Task_Dispatching_Policy;
         Gl_Restrictions             := Restrictions;
         Gl_Interrupt_States         := Interrupt_States;
         Gl_Num_Interrupt_States     := Num_Interrupt_States;
         Gl_Unreserve_All_Interrupts := Unreserve_All_Interrupts;
         Gl_Exception_Tracebacks     := Exception_Tracebacks;
         Gl_Zero_Cost_Exceptions     := Zero_Cost_Exceptions;
      end if;
   end Set_Globals;

   -----------------------------
   -- Install_Signal_Handlers --
   -----------------------------

   function Install_Signal_Handlers return Interfaces.C.int is
   begin
      Install_Handler;
      return 0;
   end Install_Signal_Handlers;

   ---------------------
   -- Install_Handler --
   ---------------------

   procedure Install_Handler is
      Mask          : aliased sigset_t;
      Signal_Action : aliased struct_sigaction;
      Result        : Interfaces.C.int;

   begin
      --  Set up signal handler to map synchronous signals to appropriate
      --  exceptions. Make sure that the handler isn't interrupted by
      --  another signal that might cause a scheduling event!

      Signal_Action.sa_handler := GNAT_Error_Handler'Address;
      Signal_Action.sa_flags := SA_ONSTACK;
      Result := sigemptyset (Mask'Access);
      Signal_Action.sa_mask := Mask;

      Result := sigaction
        (Signal (SIGFPE), Signal_Action'Unchecked_Access, null);

      Result := sigaction
        (Signal (SIGILL), Signal_Action'Unchecked_Access, null);

      Result := sigaction
        (Signal (SIGSEGV), Signal_Action'Unchecked_Access, null);

      Result := sigaction
        (Signal (SIGBUS), Signal_Action'Unchecked_Access, null);

      Handler_Installed := 1;
   end Install_Handler;

end System.Init;
