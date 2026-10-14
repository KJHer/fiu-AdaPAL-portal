
with Bedrock.Screen;     use Bedrock.Screen;
with Ada.Text_IO;        use Ada.Text_IO;
with Portal;
with Portal.Backend;     use Portal.Backend;
with Portal.Framebuffer; use Portal.Framebuffer;
with Portal.Input;       use Portal.Input;

procedure Linux_Demo is

   W_Px : constant := 800;
   H_Px : constant := 600;

   Frame : Buffer (H_Px - 1, W_Px - 1);
   Win   : Window_Id;
   OK    : Boolean;
   E     : Event;

   Running     : Boolean := True;
   

begin
   Initialize (OK);

   if not OK then
      Put_Line ("Portal initialization failed");
      return;
   end if;

   Create_Window
  ("Press a key", (W_Px, H_Px), (others => <>), Win);

   if Win = No_Window then
      Put_Line ("Window creation failed");
      Finalize;
      return;
   end if;

   while Running loop

      loop
         Poll (E);
         exit when E.Kind = None;

         case E.Kind is
            when Quit | Window_Close =>
               Running := False;

            when Key_Down =>
               Put_Line ("Key Pressed: " & E.Key'Image);
               Set_Title (Win, "Key Pressed: " & E.Key'Image);

               if E.Key = Key_Escape then
                  Running := False;
               end if;

            when others =>
               null;
         end case;
      end loop;

      Clear (Frame, (30, 30, 30, 255));

      

      Present (Win, Frame);
      Sleep (16);

   end loop;

   Destroy_Window (Win);
   Finalize;

end Linux_Demo;
